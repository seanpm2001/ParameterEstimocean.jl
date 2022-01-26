module OceanTurbulenceParameterEstimation

export
    SyntheticObservations,
    InverseProblem,
    FreeParameters,
    IdentityNormalization,
    ZScore,
    forward_map,
    forward_run!,
    observation_map,
    observation_times,
    observation_map_variance_across_time,
    ensemble_column_model_simulation,
    ConcatenatedOutputMap,
    eki,
    lognormal_with_mean_std,
    iterate!,
    EnsembleKalmanInversion,
    NaNResampler,
    FullEnsembleDistribution,
    SuccessfulEnsembleDistribution,
    ConstrainedNormal

include("Observations.jl")
include("EnsembleSimulations.jl")
include("TurbulenceClosureParameters.jl")
include("InverseProblems.jl")
include("EnsembleKalmanInversions.jl")

using .Observations:
    SyntheticObservations,
    ZScore,
    observation_times

using .EnsembleSimulations: ensemble_column_model_simulation

using .TurbulenceClosureParameters: FreeParameters

using .InverseProblems:
    InverseProblem,
    forward_map,
    forward_run!,
    observation_map,
    observation_map_variance_across_time,
    ConcatenatedOutputMap

using .EnsembleKalmanInversions:
    iterate!,
    EnsembleKalmanInversion,
    ConstrainedNormal,
    lognormal_with_mean_std,
    NaNResampler,
    FullEnsembleDistribution,
    SuccessfulEnsembleDistribution

#####
##### Data!
#####

using DataDeps

function __init__()
    # Register LESbrary data
    lesbrary_url = "https://github.com/CliMA/OceananigansArtifacts.jl/raw/glw/lesbrary2/LESbrary/idealized/"

    cases = ["free_convection",
             "weak_wind_strong_cooling", 
             "strong_wind_weak_cooling", 
             "strong_wind",
             "strong_wind_no_rotation"]

    two_day_suite_url = lesbrary_url * "two_day_suite/"

    glom_url(suite, resolution, case) = string(lesbrary_url,
                                               suite, "/", resolution, "_resolution",
                                               case, "_instantaneous_statistics.jld2")

    two_day_suite_2m_paths  = [glom_url( "two_day_suite", "4m_4m_2m", case) for case in cases]
    two_day_suite_4m_paths  = [glom_url( "two_day_suite", "8m_8m_4m", case) for case in cases]
    four_day_suite_2m_paths = [glom_url("four_day_suite", "4m_4m_2m", case) for case in cases]
    four_day_suite_4m_paths = [glom_url("four_day_suite", "8m_8m_4m", case) for case in cases]
    six_day_suite_2m_paths  = [glom_url( "six_day_suite", "4m_4m_2m", case) for case in cases]
    six_day_suite_4m_paths  = [glom_url( "six_day_suite", "8m_8m_4m", case) for case in cases]
                              
    DataDeps.register(DataDep("two_day_suite_2m",  "Idealized 2 day simulation data with 2m vertical resolution", two_day_suite_2m_paths))
    DataDeps.register(DataDep("two_day_suite_4m",  "Idealized 2 day simulation data with 4m vertical resolution", two_day_suite_4m_paths))
    DataDeps.register(DataDep("four_day_suite_2m", "Idealized 4 day simulation data with 2m vertical resolution", four_day_suite_2m_paths))
    DataDeps.register(DataDep("four_day_suite_4m", "Idealized 4 day simulation data with 4m vertical resolution", four_day_suite_4m_paths))
    DataDeps.register(DataDep("six_day_suite_2m",  "Idealized 6 day simulation data with 2m vertical resolution", six_day_suite_2m_paths))
    DataDeps.register(DataDep("six_day_suite_4m",  "Idealized 6 day simulation data with 4m vertical resolution", six_day_suite_4m_paths))
end

end # module

