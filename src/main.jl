using PowerModels, PowerModelsWildfire
using JuMP, SCIP, CPLEX 

PowerModels.silence()
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

# modify risk upper bound 
function modify_risk_ub(data::Dict{String,Any}, ub::Number)
    data["risk_ub"] = ub
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

# instantiate the model using DC power flow and the OPS formulation 
get_ops_pm(data::Dict) = instantiate_model(data, 
    _PM.DCPPowerModel, 
    _PMW.build_ops; 
    ref_extensions=[_PM.ref_add_on_off_va_bounds!]
)

get_equitable_ops_pm(data::Dict) = instantiate_model(data, 
    _PM.DCPPowerModel, 
    _PMW.build_equitable_ops; 
    ref_extensions=[_PM.ref_add_on_off_va_bounds!]
)

# solve Optimal Power Shut-off model 
function solve_ops(pm::AbstractPowerModel; optimizer = cplex)::NamedTuple 
    # solve model 
    result = optimize_model!(pm, optimizer = optimizer)

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

    return (result = result, risk = risk)
end 


function main() 
    data = file |> get_data 
    modify_risk_weight(data, 0.2)
    pm = data |> get_ops_pm

    demand = compute_demand(pm)
    total_risk = pm |> compute_total_risk

    for risk_ub in range(0, total_risk; length = 5)
        modify_risk_ub(data, risk_ub)
        pm_ops = data |> get_ops_pm 
        result_ops, risk_ops = solve_ops(pm_ops)
        served_ops = compute_load_served(result_ops)
        pm_eq_ops = data |> get_equitable_ops_pm 
        result_eq_ops, risk_eq_ops = solve_ops(pm_eq_ops; optimizer = scip)
        served_eq_ops = compute_load_served(result_eq_ops)
        println("##### $risk_ub #####")
        @show risk_ops 
        @show risk_eq_ops
        println("total load: $(demand.total)")
        println("total load served ops: $(served_ops.total)")
        println("total load served eq ops: $(served_eq_ops.total)")
        println("###################")
    end 
    # result, risk = pm |> solve_ops 
    # served = compute_load_served(result)
    
    # println("total load: $(demand.total)")
    # println("total risk: $total_risk")
    # println("total load served: $(served.total)")
    # println("actual risk: $risk")
end 

main()





