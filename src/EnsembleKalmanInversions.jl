module EnsembleKalmanInversions

export
    iterate!,
    pseudo_step!,
    EnsembleKalmanInversion,
    Resampler,
    FullEnsembleDistribution,
    NormExceedsMedian,
    ObjectiveLossThreshold,
    SuccessfulEnsembleDistribution

using OffsetArrays
using ProgressBars
using Random
using Printf
using LinearAlgebra
using Statistics
using Distributions
using EnsembleKalmanProcesses:
    get_u_final,
    Inversion,
    Sampler,
    update_ensemble!,
    EnsembleKalmanProcess

using ..Parameters: unconstrained_prior, transform_to_constrained, inverse_covariance_transform
using ..InverseProblems: Nensemble, observation_map, forward_map, BatchedInverseProblem
using ..InverseProblems: inverting_forward_map

using Oceananigans.Utils: prettytime, prettysummary
using MPI

#const DistributedEnsembleKalmanInversion = EnsembleKalmanInversion{E, <:DistributedInverseProblem}

mutable struct EnsembleKalmanInversion{E, I, M, O, S, R, X, G, C, P, T, F}
    inverse_problem :: I
    ensemble_kalman_process :: E
    mapped_observations :: M
    noise_covariance :: O
    iteration :: Int
    pseudotime :: Float64
    pseudo_Δt :: Float64
    iteration_summaries :: S
    resampler :: R
    unconstrained_parameters :: X
    forward_map_output :: G
    pseudo_stepping :: C
    precomputed_arrays :: P
    tikhonov :: T
    mark_failed_particles :: F
end

function Base.show(io::IO, eki::EnsembleKalmanInversion)
    print(io, "EnsembleKalmanInversion", '\n')

    ip = eki.inverse_problem
    if ip isa BatchedInverseProblem
        print(io, "├── inverse_problem: ", summary(ip), '\n',
                  "│   ├── free_parameters: $(summary(ip.free_parameters))", '\n',
                  "│   ├── weights: ", ip.weights, '\n')

        Nb = length(ip.batch)
        for (n, bip) in enumerate(ip.batch)
            sim_str = "Simulation on $(summary(bip.simulation.model.grid)) with Δt=$(bip.simulation.Δt)"

            L = n == Nb ? "└" : "├"
            I = n == Nb ? " " : "│"

            nstr = @sprintf("%-8d", n)

            print(io, "│   $(L)─ $(nstr) weight: ", prettysummary(ip.weights[n]), '\n',
                      "│   $I  ├─ observations: ", summary(bip.observations), '\n',
                      "│   $I  └─── simulation: ", sim_str, '\n')
        end
        print(io, "│", '\n')
    else
        print(io, "├── inverse_problem: ", summary(eki.inverse_problem), '\n')
    end      

    print(io, "├── ensemble_kalman_process: ", summary(eki.ensemble_kalman_process), '\n',
              "├── mapped_observations: ", summary(eki.mapped_observations), '\n',
              "├── noise_covariance: ", summary(eki.noise_covariance), '\n',
              "├── pseudo_stepping: $(eki.pseudo_stepping)", '\n',
              "├── iteration: $(eki.iteration)", '\n',
              "├── resampler: $(summary(eki.resampler))", '\n',
              "├── unconstrained_parameters: $(summary(eki.unconstrained_parameters))", '\n',
              "├── forward_map_output: $(summary(eki.forward_map_output))", '\n',
              "└── mark_failed_particles: $(summary(eki.mark_failed_particles))")
end

construct_noise_covariance(noise_covariance::AbstractMatrix, y) = noise_covariance

function construct_noise_covariance(noise_covariance::Number, y)
    η = convert(eltype(y), noise_covariance)
    Nobs = length(y)
    return Matrix(η * I, Nobs, Nobs)
end

struct UninitializedForwardMapOutput end

"""
    EnsembleKalmanInversion(inverse_problem;
                            noise_covariance = 1,
                            pseudo_stepping = nothing,
                            pseudo_Δt = 1.0,
                            resampler = Resampler(),
                            unconstrained_parameters = nothing,
                            forward_map_output = nothing,
                            mark_failed_particles = NormExceedsMedian(1e9),
                            ensemble_kalman_process = Inversion(),
                            Nensemble = Nensemble(inverse_problem),
                            tikhonov = false)

Return an object that finds local minima of the inverse problem:

```math
y = G(θ) + η,
```

for the parameters ``θ``, where ``y`` is a vector of observations (often normalized),
``G(θ)`` is a forward map that predicts the observations, and ``η ∼ 𝒩(0, Γ_y)`` is zero-mean
random noise with a `noise_covariance` matrix ``Γ_y`` representing uncertainty in the observations.

The "forward map output" `G` is model output mapped to the space of `inverse_problem.observations`.

(For more details on the Ensemble Kalman Inversion algorithm refer to the
[EnsembleKalmanProcesses.jl Documentation](https://clima.github.io/EnsembleKalmanProcesses.jl/stable/ensemble_kalman_inversion/).)

Positional Arguments
====================

- `inverse_problem` (`InverseProblem`): Represents an inverse problem representing the comparison between
                                        synthetic observations generated by
                                        [Oceananigans.jl](https://clima.github.io/OceananigansDocumentation/stable/)
                                        and model predictions, also generated by Oceananigans.jl.

Keyword Arguments
=================
- `noise_covariance` (`Number` or `AbstractMatrix`): Covariance matrix representing observational uncertainty.
                                                     `noise_covariance::Number` is converted to a scaled identity matrix.

- `pseudo_stepping`: The pseudo time-stepping scheme for stepping EKI forward.

- `pseudo_Δt`: The pseudo time-step; Default: 1.0.

- `resampler`: controls particle resampling procedure. See `Resampler`.

- `unconstrained_parameters`: Default: `nothing`.

- `forward_map_output`: Default: `nothing`.

- `mark_failed_particles`: The particle failure condition. Default: `NormExceedsMedian(1e9)`.

- `ensemble_kalman_process`: The Ensemble Kalman process. Default: `Inversion()`.

- `tikhonov`: Whether to incorporate prior information in the EKI objective via Tikhonov regularization.
  See Chada et al. "Tikhonov Regularization Within Ensemble Kalman Inversion." SIAM J. Numer. Anal. 2020.


"""
function EnsembleKalmanInversion(inverse_problem;
                                 noise_covariance = 1,
                                 pseudo_stepping = nothing,
                                 pseudo_Δt = 1.0,
                                 resampler = Resampler(),
                                 unconstrained_parameters = nothing,
                                 forward_map_output = nothing,
                                 mark_failed_particles = NormExceedsMedian(1e9),
                                 ensemble_kalman_process = Inversion(),
                                 Nensemble = Nensemble(inverse_problem),
                                 tikhonov = false)

    if ensemble_kalman_process isa Sampler && !isnothing(pseudo_stepping)
        @warn "Process is $ensemble_kalman_process; ignoring keyword argument pseudo_stepping=$pseudo_stepping."
        pseudo_stepping = nothing
    end

    free_parameters = inverse_problem.free_parameters
    priors = free_parameters.priors
    Nθ = length(priors)
    Nens = Nensemble

    # Generate an initial sample of parameters
    unconstrained_priors = NamedTuple(name => unconstrained_prior(priors[name])
                                      for name in free_parameters.names)

    if isnothing(unconstrained_parameters)
        isnothing(forward_map_output) || forward_map_output isa UninitializedForwardMapOutput ||
            @warn("iterate! may not succeed when forward_map_output is provided without accompanying unconstrained_parameters.")

        unconstrained_parameters = [rand(unconstrained_priors[i]) for i=1:Nθ, k=1:Nens]
    end

    # Build EKP-friendly observations "y" and the covariance matrix of observational uncertainty "Γy"
    y = dropdims(observation_map(inverse_problem), dims=2) # length(forward_map_output) column vector
    Γy = construct_noise_covariance(noise_covariance, y)
    Xᵢ = unconstrained_parameters
    iteration = 0
    pseudotime = 0.0

    # Pre-compute Γθ^(-1/2) and μθ
    unconstrained_priors = collect(unconstrained_priors)
    Γθ = diagm(getproperty.(unconstrained_priors, :σ).^2)
    μθ = getproperty.(unconstrained_priors, :μ)

    precomputed_arrays = Dict(:inv_Γy => inv(Γy), 
                              :inv_sqrt_Γy => inv(sqrt(Γy)),
                              :Γθ => Γθ,
                              :inv_sqrt_Γθ => inv(sqrt(Γθ)),
                              :μθ => μθ)

    Σ = cat(Γy, Γθ, dims=(1,2))
    precomputed_augmented_arrays = Dict(:y_augmented => vcat(y, zeros(Nθ)),
                                        :η_mean_augmented => vcat(zeros(length(y)), -μθ),
                                        :Σ => Σ, 
                                        :inv_Σ => inv(Σ),
                                        :inv_sqrt_Σ => inv(sqrt(Σ)))

    precomputed_arrays = merge(precomputed_arrays, precomputed_augmented_arrays)

    eki′ = EnsembleKalmanInversion(inverse_problem,
                                   ensemble_kalman_process,
                                   y,
                                   Γy,
                                   iteration,
                                   pseudotime,
                                   pseudo_Δt,
                                   nothing,
                                   resampler,
                                   Xᵢ,
                                   forward_map_output,
                                   pseudo_stepping,
                                   precomputed_arrays,
                                   tikhonov,
                                   mark_failed_particles)

    if isnothing(forward_map_output) # execute forward map to generate initial summary and forward_map_output
        @info "Executing forward map while building EnsembleKalmanInversion..."
        start_time = time_ns()
        forward_map_output = resampling_forward_map!(eki′, Xᵢ)
        elapsed_time = (time_ns() - start_time) * 1e-9
        @info "    ... done ($(prettytime(elapsed_time)))."
    elseif forward_map_output isa UninitializedForwardMapOutput 
        # size(forward_map_output) = (Nobs, Nensemble)
        Nobs = length(y)
        forward_map_output = zeros(Nobs, Nens)
    end

    summary = IterationSummary(eki′, Xᵢ, forward_map_output)
    iteration_summaries = OffsetArray([summary], -1)

    eki = EnsembleKalmanInversion(inverse_problem,
                                  eki′.ensemble_kalman_process,
                                  eki′.mapped_observations,
                                  eki′.noise_covariance,
                                  iteration,
                                  pseudotime,
                                  eki′.pseudo_Δt,
                                  iteration_summaries,
                                  eki′.resampler,
                                  eki′.unconstrained_parameters,
                                  forward_map_output,
                                  eki′.pseudo_stepping,
                                  eki′.precomputed_arrays,
                                  eki′.tikhonov,
                                  eki′.mark_failed_particles)

    return eki
end

include("iteration_summary.jl")
include("resampling.jl")

#####
##### Iterating
#####

function resampling_forward_map!(eki, X=eki.unconstrained_parameters)
    G = inverting_forward_map(eki.inverse_problem, X) # (len(G), Nensemble)
    resample!(eki.resampler, X, G, eki)
    return G
end

"""
    iterate!(eki::EnsembleKalmanInversion;
             iterations = 1,
             pseudo_Δt = eki.pseudo_Δt,
             pseudo_stepping = eki.pseudo_stepping,
             show_progress = false,
             kwargs...)

Convenience function for running `pseudo_step!` multiple times with the same argument.
Iterates the ensemble Kalman inversion dynamic forward by `iterations` given current state `eki`.

Keyword arguments
=================

- `iterations` (`Int`): Number of iterations to run. (Default: 1)

- `show_progress` (`Boolean`): Whether to show a progress bar. (Default: `true`)

- `kwargs` (`NamedTuple`): Keyword arguments to be passed to `pseudo_step!` at each iteration. (Defaults: see `pseudo_step!`)

Return
======

- `best_parameters`: the ensemble mean of all parameter values after the last iteration.
"""
function iterate!(eki::EnsembleKalmanInversion;
                  iterations = 1,
                  pseudo_Δt = eki.pseudo_Δt,
                  pseudo_stepping = eki.pseudo_stepping,
                  show_progress = false,
                  kwargs...)

    iterator = show_progress ? ProgressBar(1:iterations) : 1:iterations

    for _ in iterator
        pseudo_step!(eki; kwargs...)

        # Forward map
        eki.forward_map_output = resampling_forward_map!(eki)
        summary = IterationSummary(eki, eki.unconstrained_parameters, eki.forward_map_output)
        push!(eki.iteration_summaries, summary)

        ensemble_mean = eki.iteration_summaries[end].ensemble_mean
    end

    # Return ensemble mean (best guess for optimal parameters)
    best_parameters = eki.iteration_summaries[end].ensemble_mean

    return best_parameters
end

function set_unconstrained_parameters!(eki, X)
    eki.unconstrained_parameters = X
    eki.forward_map_output = resampling_forward_map!(eki)
    return nothing
end

"""
    pseudo_step!(eki::EnsembleKalmanInversion; 
                 pseudo_Δt = nothing,
                 pseudo_stepping = nothing,
                 covariance_inflation = 0.0,
                 momentum_parameter = 0.0)

Step forward `X = eki.unconstrained_parameters` using `y = eki.mapped_observations`,
`Γy = eki.noise_covariance`, and G = `eki.forward_map_output`.

Keyword arguments
=================

- `pseudo_Δt` (`Float64` or `Nothing`): Pseudo time-step. If `pseudo_Δt` is `nothing`, the time step 
                        is set according to the algorithm specified by the `pseudo_stepping` scheme; 
                        If `pseudo_Δt` is a `Float64`, `pseudo_stepping` is ignored. 
                        (Default: `nothing`)

- `pseudo_stepping` (`Float64`): Scheme for selecting a time step if `pseudo_Δt` is `nothing`.
                                 (Default: `eki.pseudo_stepping`)
- `covariance_inflation`: (Default: 0.)

- `momentum_parameter`: (Default: 0.)
"""
function pseudo_step!(eki::EnsembleKalmanInversion; 
                      pseudo_Δt = nothing,
                      pseudo_stepping = nothing,
                      covariance_inflation = 0.0,
                      momentum_parameter = 0.0)

    if isnothing(pseudo_Δt)
        pseudo_Δt = eki.pseudo_Δt
        pseudo_stepping = eki.pseudo_stepping
    end

    eki.unconstrained_parameters, adaptive_Δt = step_parameters(eki, pseudo_stepping; 
                                                                Δt = pseudo_Δt,
                                                                covariance_inflation,
                                                                momentum_parameter)

    last_summary = eki.iteration_summaries[end]
    eki.iteration_summaries[end] = IterationSummary(last_summary.unconstrained_parameters,
                                                    last_summary.parameters,
                                                    last_summary.ensemble_mean,
                                                    last_summary.ensemble_cov,
                                                    last_summary.ensemble_var,
                                                    last_summary.mean_square_errors,
                                                    last_summary.objective_values,
                                                    last_summary.iteration,
                                                    last_summary.pseudotime,
                                                    adaptive_Δt)

    # Update the pseudoclock
    eki.iteration += 1
    eki.pseudotime += adaptive_Δt
    eki.pseudo_Δt = adaptive_Δt

    return nothing
end

#####
##### Failure conditions
#####

"""
    struct NormExceedsMedian{T}

The particle failure condition. A particle is marked "failed" if the forward map norm is
larger than `minimum_relative_norm` times more than the median value of the ensemble.
By default `minimum_relative_norm = 1e9`.
"""
struct NormExceedsMedian{T}
    minimum_relative_norm :: T
    NormExceedsMedian(minimum_relative_norm = 1e9) = 
        minimum_relative_norm < 0 ? error("minimum_relative_norm must non-negative") :
        new{typeof(minimum_relative_norm)}(minimum_relative_norm)
end

""" Return a BitVector indicating whether the norm of the forward map
for a given particle exceeds the median by `mrn.minimum_relative_norm`."""
function (mrn::NormExceedsMedian)(X, G, eki)
    ϵ = mrn.minimum_relative_norm

    G_norm = mapslices(norm, G, dims=1)
    finite_G_norm = filter(!isnan, G_norm)

    # If all particles fail, median_norm cannot be computed, so we set to 0.
    median_norm = length(finite_G_norm) == 0 ? zero(eltype(finite_G_norm)) : median(finite_G_norm)
    failed(column) = any(isnan.(column)) || norm(column) > ϵ * median_norm

    return vec(mapslices(failed, G; dims=1))
end

struct ObjectiveLossThreshold{T, S, D}
    multiple :: T
    baseline :: S
    distance :: D
end

median_absolute_deviation(X, x₀) = median(abs.(X .- x₀))

function best_next_best(X, x₀)
    I = sortperm(X)
    i₁, i₂ = I[1:2]
    return X[i₂] - X[i₁]
end

nanmedian(X) = median(filter(!isnan, X))
nanminimum(X) = minimum(filter(!isnan, X))

"""
    ObjectiveLossThreshold(multiple = 4.0;
                           baseline = nanmedian,
                           distance = median_absolute_deviation)

Return a failure criterion that defines failure for particle `k` as

```
Φₖ > baseline(Φ) + multiple * distance(Φ)
```

where `Φ` is the objective loss function.

By default, `baseline = nanmedian`, the `distance` is the 
median absolute deviation, and `multiple = 4.0`.
"""
function ObjectiveLossThreshold(multiple = 4.0;
                                baseline = nanmedian,
                                distance = median_absolute_deviation)

    return ObjectiveLossThreshold(multiple, baseline, distance)
end

function (criterion::ObjectiveLossThreshold)(X, G, eki)
    inv_sqrt_Γy = eki.precomputed_arrays[:inv_sqrt_Γy]
    y = eki.mapped_observations

    Nobs, Nens = size(G)
    objective_loss = [1/2 * norm(inv_sqrt_Γy * (y .- G[:, k]))^2 for k = 1:Nens]

    finite_loss = filter(!isnan, objective_loss)

    # Short-circuit if all particles NaN.
    if length(finite_loss) == 0
        return [true for k in 1:Nens]
    end

    baseline = criterion.baseline(objective_loss)
    distance = criterion.distance(objective_loss, baseline)
    n = criterion.multiple

    failed(loss) = isnan(loss) || loss > baseline + n * distance

    return vec(map(failed, objective_loss))
end

#####
##### Adaptive stepping
#####

function step_parameters(X, G, y, Γy, process; Δt=1.0)
    ekp = EnsembleKalmanProcess(X, y, Γy, process; Δt)
    update_ensemble!(ekp, G)
    return get_u_final(ekp)
end

# Default pseudo_stepping::Nothing --- it's not adaptive
adaptive_step_parameters(::Nothing, Xⁿ, Gⁿ, y, Γy, process; Δt) = step_parameters(Xⁿ, Gⁿ, y, Γy, process; Δt), Δt

function step_parameters(eki::EnsembleKalmanInversion, pseudo_stepping;
                         Δt = 1.0,
                         covariance_inflation = 0.0,
                         momentum_parameter = 0.0)

    Gⁿ = eki.forward_map_output
    Xⁿ = eki.unconstrained_parameters
    Xⁿ⁺¹ = similar(Xⁿ)

    # Handle failed particles
    particle_failure = eki.mark_failed_particles(Xⁿ, Gⁿ, eki)
    failures = findall(particle_failure) # indices of columns (particles) with `NaN`s
    successes = findall(.!particle_failure)
    some_failures = length(failures) > 0

    some_failures && @warn string(length(failures), " particles failed. ",
                                  "Performing ensemble update with statistics from ",
                                  length(successes), " successful particles.")

    successful_Gⁿ = Gⁿ[:, successes]
    successful_Xⁿ = Xⁿ[:, successes]

    # Construct new parameters
    successful_Xⁿ⁺¹, Δt = adaptive_step_parameters(pseudo_stepping,
                                                   successful_Xⁿ,
                                                   successful_Gⁿ,
                                                   eki;
                                                   Δt,
                                                   covariance_inflation,
                                                   momentum_parameter)

    Xⁿ⁺¹[:, successes] .= successful_Xⁿ⁺¹

    if some_failures # resample failed particles with new ensemble distribution
        new_X_distribution = ensemble_normal_distribution(successful_Xⁿ⁺¹) 
        sampled_Xⁿ⁺¹ = rand(new_X_distribution, length(failures))
        Xⁿ⁺¹[:, failures] .= sampled_Xⁿ⁺¹
    end

    return Xⁿ⁺¹, Δt
end

end # module
