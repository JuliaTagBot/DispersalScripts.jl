# data = h5open("spread_inputs_US.h5", "r")

import FieldMetadata: @relimits, limits, @reflattenable, flattenable


# Human
@relimits struct HumanDispersal
    human_exponent  | (0.0, 3.0)
    dist_exponent   | (0.0, 3.0)
    dispersalperpop | (0.0, 1e-8)
    max_dispersers  | (1e1, 1e4)
end
# Constant growth
@relimits struct ExactLogisticGrowth
    intrinsicrate | (0.0, 10.0)
end
# Dont parametrise carrycap
@reflattenable struct SuitabilityExactLogisticGrowth
    carrycap | false
end
# Kernel
@reflattenable struct ExponentialKernel
    λ | false
end
# Alee
@relimits struct AlleeExtinction
    minfounders | (2e0, 1e3)
end

FloatType = Float32

floatconvert(a::AbstractArray) = convert(Array{FloatType,2}, a)
floatconvert(x::Number) = convert(FloatType, x)

setup_comparison_rulesets(datafile) = begin

    data = h5open(datafile, "r")
    init = floatconvert(read(data["x_y_initial"]) .* 1e9) # Arbitrary initial condition
    # init = floatconvert(read(data["x_y_initial"])["melbourne"] .* 1e7) # Arbitrary initial condition
    # init = floatconvert(read(data["x_y_initial"])["seisia"] .* 1e9) # Arbitrary initial condition
    # init = floatconvert(read(data["x_y_initial"])["cairns"] .* 1e9) # Arbitrary initial condition
    # init = floatconvert(read(data["x_y_initial"])["brisbane"] .* 1e7) # Arbitrary initial condition
    cellsize = floatconvert(1.0)
    month = floatconvert(365.25)d/12
    simtimestep = month
    framesperstep = 12

    # Define parametrization objective ########################################
    detectionthreshold = floatconvert(1e7)
    occurance = convert.(Bool, read(data["state_year_spread"]))
    regionlookup = convert.(Int, replace(read(data["x_y_state"]), NaN=>0))[:, :, 1]
    steps = size(occurance, 2)
    startmonth = 5 # we start five months/frames in - in May, close to the first sighting.
                   # January has strongly negative growth rates in San Jose.
    tstop = steps * framesperstep - startmonth + 1
    objective = RegionObjective(detectionthreshold, regionlookup, occurance, framesperstep, startmonth)
    output = Dispersal.RegionOutput(init, tstop, objective)


    # Rules ###########################################################


    # Human dispersal
    human_pop = replace(floatconvert.(read(data["x_y_popdens"])), NaN=>missing)
    scale = 8
    aggregator = mean
    human_exponent = floatconvert(2.0)
    dist_exponent = floatconvert(2.0)
    dispersalperpop = floatconvert(1e-9)
    max_dispersers = floatconvert(500.0)
    shortlist_len = 100
    @time humandisp = HumanDispersal(human_pop; scale=scale, shortlist_len=shortlist_len, dispersalperpop=dispersalperpop,
                                     max_dispersers=max_dispersers, cellsize=cellsize, human_exponent=human_exponent,
                                     dist_exponent=dist_exponent, timestep=simtimestep)

    # Climate driven growth
    carrycap = floatconvert(1e8)
    pg = replace(read(data["x_y_month_intrinsicGrowthRate"]), NaN=>0)
    popgrowth = [floatconvert(pg[:, :, i]) for i in 1:size(pg, 3)]
    popgrowth = vcat(popgrowth[6:12], popgrowth[1:5])
    # Convert growth arrays to units
    growth_layers = Sequence(popgrowth .* d^-1, month);
    growth = SuitabilityExactLogisticGrowth(layers=growth_layers, carrycap=carrycap);

    # Constant growth
    constant_growth = ExactLogisticGrowth(intrinsicrate=floatconvert(0.1)d^-1, carrycap=carrycap)

    # Local dispersal
    λ = floatconvert(0.0125)
    radius = 1
    sze = 2radius + 1

    # buildhood(dm) = begin
    #     hood = DispersalKernel{radius}(;kernel=zeros(FloatType, radius, radius), cellsize=cellsize,
    #                                    formulation=ExponentialKernel(λ), distancemethod=dm)
    #     hood.kernel .* carrycap
    # end
    # using Plots
    # p = plot();
    # plot!(p, buildhood(CentroidToCentroid())[radius+1, :]; label="centroid")
    # subsample = [2, 5, 10, 20, 30]
    # ss = 10
    # for ss in subsample
    #     plot!(p, buildhood(AreaToArea(ss))[radius+1, :]; label=ss)
    # end
    # plot(p)
    # heatmap(log.(buildhood(AreaToArea(10))))

    # heatmap(log.(hood.kernel .* carrycap))
    # dm = CentroidToCentroid()
    dm = AreaToArea(30)
    @time hood = DispersalKernel{radius}(;kernel=zeros(FloatType, radius, radius), cellsize=cellsize,
                                   formulation=ExponentialKernel(λ), distancemethod=dm)
    localdisp = InwardsPopulationDispersal(hood)
    display(hood.kernel * carrycap)

    # Allee effects
    minfounders = floatconvert(10.0)
    allee = AlleeExtinction(minfounders=minfounders)

    # Mask
    masksource = read(data["x_y_month_intrinsicGrowthRate"])[:, :, 1]
    masklayer = BitArray(replace(x -> isnan(x) ? 0 : 1, masksource))

    # Define combinations for comparison  ##########################
    kwargs = (init=init, mask=masklayer, timestep=simtimestep, minval=0.0, maxval=carrycap)

    full = Ruleset(humandisp, (localdisp, allee, growth); kwargs...)
    nolocal = Ruleset(humandisp, allee, growth; kwargs...)
    noallee = Ruleset(humandisp, (localdisp, growth); kwargs...)
    nohuman = Ruleset((localdisp, allee, growth); kwargs...)
    noclimate = Ruleset(humandisp, (localdisp, allee, constant_growth); kwargs...)
    ruleset = Ruleset((localdisp, growth); kwargs...)

    ((full=full, nolocal=nolocal, noallee=noallee, nohuman=nohuman,
      noclimate=noclimate), init, tstop, objective, output)
end
