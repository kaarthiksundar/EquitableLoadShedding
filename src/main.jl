using PowerModels, PowerModelsWildfire
using JuMP, SCIP, CPLEX 

const _PM = PowerModels 
const _PMW = PowerModelsWildfire

scip = JuMP.optimizer_with_attributes(SCIP.Optimizer)
cplex = JuMP.optimizer_with_attributes(CPLEX.Optimizer)

file = "./data/RTS_GMLC_risk.m"

get_data(file) = _PM.parse_file(file)

# modify weight (alpha value) for risk: (1-alpha) * LS + alpha * Risk 
function modify_risk_weight(data::Dict{String,Any}, weight::Number = 0.5)
    (weight <= 0.0 || weight >= 1.0) && (@warn "weight $weight has to be in [0, 1]"; return)
    data["risk_weight"] = weight 
end 

# compute total risk 
function compute_total_risk(pm::AbstractPowerModel)::Number 
    total_risk = sum(gen["power_risk"] + gen["base_risk"] for (i,gen) in _PM.ref(pm, :gen)) + 
        sum(bus["power_risk"] + bus["base_risk"] for (i,bus) in _PM.ref(pm, :bus)) + 
        sum(branch["power_risk"] + branch["base_risk"] for (i,branch) in _PM.ref(pm, :branch)) + 
        sum(load["power_risk"]+ load["base_risk"] for (i,load) in _PM.ref(pm,:load))

    return round(total_risk; digits = 2)
end 

# compute total demand  
function compute_demand(pm::AbstractPowerModel)::NamedTuple 
    loads = Dict(
        i => load["pd"] for (i, load) in get(pm.data, "load", [])
    )
    total_load = loads |> values |> sum
    return (demand = loads, total = round(total_load; digits=2))
end 

# compute total load served  
function compute_load_served(result::Dict)::NamedTuple 
    load_served = Dict(
        i => round(load["pd"]; digits=2) for (i, load) in get(result["solution"], "load", [])
    )
    total_load_served = load_served |> values |> sum 
    return (load_served = load_served, total = round(total_load_served; digits=2))
end 

# solve Optimal Power Shut-off model 
function solve_ops(data::Dict)::NamedTuple 
    # instantiate the model using DC power flow and the OPS formulation 
    pm = instantiate_model(data, 
        _PM.DCPPowerModel, 
        _PMW.build_ops; 
        ref_extensions=[_PM.ref_add_on_off_va_bounds!]
    )

    # solve model 
    result = optimize_model!(pm, optimizer = cplex)

    # the on-off variables 
    z_demand = JuMP.value.(_PM.var(pm, nw_id_default, :z_demand))
    z_gen = JuMP.value.(_PM.var(pm, nw_id_default, :z_gen))
    z_branch = JuMP.value.(_PM.var(pm, nw_id_default, :z_branch))
    z_bus = JuMP.value.(_PM.var(pm, nw_id_default, :z_bus))


    # compute actual risk for ops solution 
    risk = sum(z_gen[i] * gen["power_risk"] + gen["base_risk"] for (i,gen) in _PM.ref(pm, :gen)) + 
        sum(z_bus[i] * bus["power_risk"] + bus["base_risk"] for (i,bus) in _PM.ref(pm, :bus)) + 
        sum(z_branch[i] * branch["power_risk"] + branch["base_risk"] for (i,branch) in _PM.ref(pm, :branch)) + 
        sum(z_demand[i] * load["power_risk"]+ load["base_risk"] for (i,load) in _PM.ref(pm,:load))

    risk = round(risk; digits=2)

    return (pm = pm, result = result, risk = risk)
end 


function main() 
    data = file |> get_data 
    modify_risk_weight(data, 0.2)
    pm, result, risk = data |> solve_ops 
    total_risk = pm |> compute_total_risk
    demand = compute_demand(pm) 
    served = compute_load_served(result)
    println("total load: $(demand.total)")
    println("total load served: $(served.total)")
    println("total risk: $total_risk")
    println("actual risk: $risk")
end 

main()





