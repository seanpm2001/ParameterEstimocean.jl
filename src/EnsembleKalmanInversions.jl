module EnsembleKalmanInversions

export
    iterate!,
    EnsembleKalmanInversion,
    Resampler,
    FullEnsembleDistribution,
    SuccessfulEnsembleDistribution

using OffsetArrays
using ProgressBars
using Random
using Printf
using LinearAlgebra
using Suppressor: @suppress
using Statistics
using Distributions
using EnsembleKalmanProcesses:
    get_u_final,
    EnsembleKalmanProcess

import EnsembleKalmanProcesses: update_ensemble!

using ..Parameters: unconstrained_prior, transform_to_constrained, inverse_covariance_transform
using ..InverseProblems: Nensemble, observation_map, forward_map, tupify_parameters
using ..InverseProblems: inverting_forward_map

using Oceananigans.Utils: prettytime

mutable struct EnsembleKalmanInversion{I, E, M, O, S, R, X, G}
    inverse_problem :: I
    ensemble_kalman_process :: E
    mapped_observations :: M
    noise_covariance :: O
    iteration :: Int
    iteration_summaries :: S
    resampler :: R
    unconstrained_parameters :: X
    forward_map_output :: G
end

Base.show(io::IO, eki::EnsembleKalmanInversion) =
    print(io, "EnsembleKalmanInversion", '\n',
              "├── inverse_problem: ", summary(eki.inverse_problem), '\n',
              "├── ensemble_kalman_process: ", summary(eki.ensemble_kalman_process), '\n',
              "├── mapped_observations: ", summary(eki.mapped_observations), '\n',
              "├── noise_covariance: ", summary(eki.noise_covariance), '\n',
              "├── iteration: $(eki.iteration)", '\n',
              "├── resampler: $(summary(eki.resampler))",
              "├── unconstrained_parameters: $(summary(eki.unconstrained_parameters))", '\n',
              "└── forward_map_output: $(summary(eki.forward_map_output))")

construct_noise_covariance(noise_covariance::AbstractMatrix, y) = noise_covariance

function construct_noise_covariance(noise_covariance::Number, y)
    Nobs = length(y)
    return Matrix(noise_covariance * I, Nobs, Nobs)
end
    
"""
    EnsembleKalmanInversion(inverse_problem; noise_covariance=1e-2, resampler=Resampler())

Return an object that interfaces with
[EnsembleKalmanProcesses.jl](https://github.com/CliMA/EnsembleKalmanProcesses.jl)
and uses Ensemble Kalman Inversion to iteratively solve the inverse problem:

```math
y = G(θ) + η,
```

for the parameters ``θ``, where ``y`` is a "normalized" vector of observations,
``G(θ)`` is a forward map that predicts the observations, and ``η ∼ 𝒩(0, Γ_y)`` is zero-mean
random noise with covariance matrix ``Γ_y`` representing uncertainty in the observations.

Note that ensemble Kalman inversion is guaranteed only to find a local optimum ``θ★``
to ``min || y - G(θ★) ||``.

The "forward map output" `G` can have many interpretations. The specific statistics that `G` computes
have to be selected for each use case to provide a concise summary of the complex model solution that
contains the values that we would most like to match to the corresponding truth values `y`. For example,
in the context of an ocean-surface boundary layer parametrization, this summary could be a vector of 
concatenated `u`, `v`, `b`, `e` profiles at all or some time steps of the CATKE solution.

(For more details on the Ensemble Kalman Inversion algorithm refer to the
[EnsembleKalmanProcesses.jl Documentation](https://clima.github.io/EnsembleKalmanProcesses.jl/stable/ensemble_kalman_inversion/).)

Arguments
=========

- `inverse_problem :: InverseProblem`: Represents an inverse problem representing the comparison between
                                       synthetic observations generated by
                                       [Oceananigans.jl](https://clima.github.io/OceananigansDocumentation/stable/)
                                       and model predictions, also generated by Oceananigans.jl.

- `noise_covariance` (`AbstractMatrix` or `Number`): normalized covariance representing observational
                                                     uncertainty. If `noise_covariance isa Number` then
                                                     it's converted to an identity matrix scaled by
                                                     `noise_covariance`.

- `resampler`: controls particle resampling procedure. See `Resampler`.
"""
function EnsembleKalmanInversion(inverse_problem;
                                 noise_covariance = 1e-2,
                                 resampler = nothing,
                                 unconstrained_parameters = nothing,
                                 forward_map_output = nothing,
                                 process = Inversion())

    if isnothing(unconstrained_parameters)
        isnothing(forward_map_output) ||
            throw(ArgumentError("Cannot provide forward_map_output without unconstrained_parameters."))

        free_parameters = inverse_problem.free_parameters
        priors = free_parameters.priors
        Nθ = length(priors)
        Nens = Nensemble(inverse_problem)

        # Generate an initial sample of parameters
        unconstrained_priors = NamedTuple(name => unconstrained_prior(priors[name])
                                          for name in free_parameters.names)

        unconstrained_parameters = [rand(unconstrained_priors[i]) for i=1:Nθ, k=1:Nens]
    end

    # Build EKP-friendly observations "y" and the covariance matrix of observational uncertainty "Γy"
    y = dropdims(observation_map(inverse_problem), dims=2) # length(forward_map_output) column vector
    Γy = construct_noise_covariance(noise_covariance, y)
    Xᵢ = unconstrained_parameters
    iteration = 0

    eki′ = EnsembleKalmanInversion(inverse_problem,
                                   process,
                                   y,
                                   Γy,
                                   iteration,
                                   nothing,
                                   resampler,
                                   Xᵢ,
                                   forward_map_output)

    if isnothing(forward_map_output) # execute forward map to generate initial summary and forward_map_output
        @info "Executing forward map while building EnsembleKalmanInversion..."
        start_time = time_ns()
        forward_map_output = resampling_forward_map!(eki′, Xᵢ)
        elapsed_time = (time_ns() - start_time) * 1e-9
        @info "    ... done ($(prettytime(elapsed_time)))."
    end

    summary = IterationSummary(eki′, Xᵢ, forward_map_output)
    iteration_summaries = OffsetArray([summary], -1)

    eki = EnsembleKalmanInversion(inverse_problem,
                                  eki′.ensemble_kalman_process,
                                  eki′.mapped_observations,
                                  eki′.noise_covariance,
                                  iteration,
                                  iteration_summaries,
                                  eki′.resampler,
                                  eki′.unconstrained_parameters,
                                  forward_map_output)

    return eki
end

struct IterationSummary{P, M, C, V, E}
    parameters :: P     # constrained
    ensemble_mean :: M  # constrained
    ensemble_cov :: C   # constrained
    ensemble_var :: V
    mean_square_errors :: E
    iteration :: Int
end

"""
    IterationSummary(eki, X, forward_map_output=nothing)

Return the summary for ensemble Kalman inversion `eki`
with unconstrained parameters `X` and `forward_map_output`.
"""
function IterationSummary(eki, X, forward_map_output=nothing)
    priors = eki.inverse_problem.free_parameters.priors

    ensemble_mean = mean(X, dims=2)[:] 
    constrained_ensemble_mean = transform_to_constrained(priors, ensemble_mean)

    ensemble_covariance = cov(X, dims=2)
    constrained_ensemble_covariance = inverse_covariance_transform(values(priors), X, ensemble_covariance)
    constrained_ensemble_variance = tupify_parameters(eki.inverse_problem, diag(constrained_ensemble_covariance))

    constrained_parameters = transform_to_constrained(priors, X)

    if !isnothing(forward_map_output)
        Nobs, Nens= size(forward_map_output)
        y = eki.mapped_observations
        G = forward_map_output
        mean_square_errors = [mapreduce((x, y) -> (x - y)^2, +, y, view(G, :, k)) / Nobs for k = 1:Nens]
    else
        mean_square_errors = nothing
    end

    return IterationSummary(constrained_parameters,
                            constrained_ensemble_mean,
                            constrained_ensemble_covariance,
                            constrained_ensemble_variance,
                            mean_square_errors,
                            eki.iteration)
end

function Base.show(io::IO, is::IterationSummary)
    max_error, imax = findmax(is.mean_square_errors)
    min_error, imin = findmin(is.mean_square_errors)

    names = keys(is.ensemble_mean)
    parameter_matrix = [is.parameters[k][name] for name in names, k = 1:length(is.parameters)]
    min_parameters = minimum(parameter_matrix, dims=2)
    max_parameters = maximum(parameter_matrix, dims=2)

    print(io, summary(is), '\n')

    print(io, "                      ", param_str.(keys(is.ensemble_mean))..., '\n',
              "       ensemble_mean: ", param_str.(values(is.ensemble_mean))..., '\n',
              particle_str("best", is.mean_square_errors[imin], is.parameters[imin]), '\n',
              particle_str("worst", is.mean_square_errors[imax], is.parameters[imax]), '\n',
              "             minimum: ", param_str.(min_parameters)..., '\n',
              "             maximum: ", param_str.(max_parameters)..., '\n',
              "   ensemble_variance: ", param_str.(values(is.ensemble_var))...)

    return nothing
end

Base.summary(is::IterationSummary) = string("IterationSummary for ", length(is.parameters),
                                            " particles and ", length(keys(is.ensemble_mean)),
                                            " parameters at iteration ", is.iteration)

function param_str(p::Symbol)
    p_str = string(p)
    length(p_str) > 9 && (p_str = p_str[1:9])
    return @sprintf("% 10s | ", p_str)
end

param_str(p::Number) = @sprintf("% -1.3e | ", p)

particle_str(particle, error, parameters) =
    @sprintf("% 11s particle: ", particle) *
    string(param_str.(values(parameters))...) *
    @sprintf("error = %.6e", error)

include("resampling.jl")

function resampling_forward_map!(eki, X=eki.unconstrained_parameters)
    G = inverting_forward_map(eki.inverse_problem, X) # (len(G), Nensemble)
    resample!(eki.resampler, X, G, eki)
    return G
end

function step_parameters(X, G, y, Γy, process; step_size=1)
    ekp = EnsembleKalmanProcess(X, y, Γy, process)
    update_ensemble!(ekp, G, Δt_new=step_size)
    return get_u_final(ekp)
end

function step_parameters(eki::EnsembleKalmanInversion, convergence_rate)
    process = eki.ensemble_kalman_process

    y = eki.mapped_observations
    Γy = eki.noise_covariance

    Xⁿ = eki.unconstrained_parameters
    G = eki.forward_map_output

    Xⁿ⁺¹ = similar(Xⁿ)

    nan_values = column_has_nan(G)
    failed_columns = findall(nan_values) # indices of columns (particles) with `NaN`s
    succesful_columns = findall(.!nan_values)
    some_failures = length(failed_columns) > 0

    successful_G = G[:, succcesful_columns]
    successful_Xⁿ = Xⁿ[:, succesful_columns]

    # Step forward with unity step size
    succesful_Xⁿ⁺¹ = step_parameters(successful_Xⁿ, successful_Gⁿ, y, Γy, process; step_size=1)

    if !isnothing(convergence_rate) # recalculate step_size
        # The "volume" of the particle ensemble
        Vⁿ = det(cov(successful_Xⁿ))
        Vⁿ⁺¹ = det(cov(successful_Xⁿ⁺¹))

        # Scale step-size so that the _new_ volume is `convergence_rate` smaller than Vⁿ
        step_size = Vⁿ / Vⁿ⁺¹ * convergence_rate
        succesful_Xⁿ⁺¹ = step_parameters(successful_Xⁿ, successful_Gⁿ, y, Γy, process; step_size)
    end

    Xⁿ⁺¹[:, succesful_columns] .= succesful_Xⁿ⁺¹

    if some_failures # resample failed particles with new ensemble distribution
        new_X_distribution = ensemble_normal_distribution(candidate_Xⁿ⁺¹) 
        sampled_Xⁿ⁺¹ = rand(new_X_distribution, nan_count)
        Xⁿ⁺¹[:, failed_columns] .= sampled_Xⁿ⁺¹
    end

    return Xⁿ⁺¹
end

"""
    iterate!(eki::EnsembleKalmanInversion; iterations = 1, show_progress = true)

Iterate the ensemble Kalman inversion problem `eki` forward by `iterations`.

Return
======

- `best_parameters`: the ensemble mean of all parameter values after the last iteration.
"""
function iterate!(eki::EnsembleKalmanInversion;
                  iterations = 1,
                  convergence_rate = nothing,
                  show_progress = true)

    iterator = show_progress ? ProgressBar(1:iterations) : 1:iterations

    for _ in iterator
        eki.unconstrained_parameters = step_parameters(eki, convergence_rate)
        eki.iteration += 1

        # Forward map
        G = resampling_forward_map!(eki) 
        eki.forward_map_output = G
        summary = IterationSummary(eki, eki.unconstrained_parameters, eki.forward_map_output)
        push!(eki.iteration_summaries, summary)
    end

    # Return ensemble mean (best guess for optimal parameters)
    best_parameters = eki.iteration_summaries[end].ensemble_mean

    return best_parameters
end

end # module

