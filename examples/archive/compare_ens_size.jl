pushfirst!(LOAD_PATH, joinpath(@__DIR__, ".."))

using Distributions
using Oceananigans
using Oceananigans.Units
using Oceananigans.Models.HydrostaticFreeSurfaceModels: ColumnEnsembleSize
using Oceananigans.TurbulenceClosures: ConvectiveAdjustmentVerticalDiffusivity
using OceanTurbulenceParameterEstimation
using Plots, LinearAlgebra

iterations = 20

all_ensemble_sizes = [20,50,100,200]
all_weight_distances = []
for ensemble_size in all_ensemble_sizes
    #####
    ##### Parameters
    #####

    Nz = 32
    Lz = 128
    Qᵇ = 1e-8
    Qᵘ = -1e-5
    Δt = 10.0
    f₀ = 1e-4
    N² = 1e-6
    stop_time = 16hours
    save_interval = 1hour
    experiment_name = "convective_adjustment"
    data_path = experiment_name * ".jld2"
    generate_observations = false

    # "True" parameters to be estimated by calibration
    convective_κz = 1.0
    convective_νz = 0.9
    background_κz = 1e-4
    background_νz = 1e-5

    θ★ = [convective_κz; background_κz; convective_νz; background_νz]

    #####
    ##### Generate synthetic observations
    #####

    if generate_observations || !(isfile(data_path))
        grid = RegularRectilinearGrid(size=Nz, z=(-Lz, 0), topology=(Flat, Flat, Bounded))
        closure = ConvectiveAdjustmentVerticalDiffusivity(; convective_κz, background_κz, convective_νz, background_νz)
        coriolis = FPlane(f=f₀)
                                            
        u_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(Qᵘ))
        b_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(Qᵇ), bottom = GradientBoundaryCondition(N²))
        
        model = HydrostaticFreeSurfaceModel(grid = grid,
                                            tracers = :b,
                                            buoyancy = BuoyancyTracer(),
                                            boundary_conditions = (; u=u_bcs, b=b_bcs),
                                            coriolis = coriolis,
                                            closure = closure)
                                            
        set!(model, b = (x, y, z) -> N² * z)
        
        simulation = Simulation(model; Δt, stop_time)
        
        simulation.output_writers[:fields] = JLD2OutputWriter(model, merge(model.velocities, model.tracers),
                                                            schedule = TimeInterval(save_interval),
                                                            prefix = experiment_name,
                                                            array_type = Array{Float64},
                                                            field_slicer = nothing,
                                                            force = true)
        
        run!(simulation)
    end

    #####
    ##### Load truth data as observations
    #####

    data_path = experiment_name * ".jld2"

    observations = OneDimensionalTimeSeries(data_path, field_names=(:u, :b), normalize=ZScore)

    #####
    ##### Set up ensemble model
    #####

    column_ensemble_size = ColumnEnsembleSize(Nz=Nz, ensemble=(ensemble_size, 1), Hz=1)
    ensemble_grid = RegularRectilinearGrid(size=column_ensemble_size, z = (-Lz, 0), topology = (Flat, Flat, Bounded))
    closure_ensemble = [ConvectiveAdjustmentVerticalDiffusivity(; convective_κz, background_κz) for i = 1:ensemble_grid.Nx, j = 1:ensemble_grid.Ny]
    coriolis_ensemble = [FPlane(f=f₀) for i = 1:ensemble_grid.Nx, j = 1:ensemble_grid.Ny]

    ensemble_b_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(Qᵇ), bottom = GradientBoundaryCondition(N²))
    ensemble_u_bcs = FieldBoundaryConditions(top = FluxBoundaryCondition(Qᵘ))

    ensemble_model = HydrostaticFreeSurfaceModel(grid = ensemble_grid,
                                                tracers = :b,
                                                buoyancy = BuoyancyTracer(),
                                                boundary_conditions = (; u=ensemble_u_bcs, b=ensemble_b_bcs),
                                                coriolis = coriolis_ensemble,
                                                closure = closure_ensemble)

    set!(ensemble_model, b = (x, y, z) -> N² * z)

    ensemble_simulation = Simulation(ensemble_model; Δt, stop_time)

    pop!(ensemble_simulation.diagnostics, :nan_checker)
    #####
    ##### Build free parameters
    #####

    priors = (
        convective_κz = lognormal_with_mean_std(1.2, 0.5),
        background_κz = lognormal_with_mean_std(1e-4, 1e-4),
        convective_νz = lognormal_with_mean_std(1.2, 0.5),
        background_νz = lognormal_with_mean_std(1e-5, 1e-5),
    )

    # priors = (
    #     convective_κz = LogNormal(0, 1.2),
    #     background_κz = LogNormal(0, 1.2),
    #     convective_νz = LogNormal(0, 1.2),
    #     background_νz = LogNormal(0, 1.2)
    # )

    free_parameters = FreeParameters(priors)

    #####
    ##### Build the Inverse Problem
    #####

    calibration = InverseProblem(observations, ensemble_simulation, free_parameters)

    # # forward_map(calibration, [θ★ for _ in 1:ensemble_size])
    # x = forward_map(calibration, [θ★ for _ in 1:ensemble_size])[:, 1:1]
    # y = observation_map(calibration)

    # # Assert that G(θ*) ≈ y
    # @show x == y

    eki = EnsembleKalmanInversion(calibration; noise_covariance=1e-2)
    params = iterate!(eki; iterations = iterations)

    weight_distances = [norm([eki.iteration_summaries[i].ensemble_mean...] - θ★) for i in 1:iterations]

    push!(all_weight_distances, weight_distances)
end

p = plot()
for (i,n_ens) in enumerate(all_ensemble_sizes)
    plot!(1:iterations, all_weight_distances[i], label=string(n_ens))
end
savefig(p, "compare_ens_size.png")