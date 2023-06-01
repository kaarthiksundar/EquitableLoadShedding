using PowerModels, PowerModelsWildfire
using JuMP, SCIP, CPLEX 
import JSON


PowerModels.silence()
const _PM = PowerModels 
const _PMW = PowerModelsWildfire



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

# modify the log constant 
function modify_log_constant(data::Dict{String,Any}, k::Number) 
    data["log_constant"] = k
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
function solve_ops(pm::AbstractPowerModel; optimizer = :cplex)::NamedTuple 
    scip = SCIP.Optimizer()
    MOI.set(scip, MOI.RawOptimizerAttribute("display/verblevel"), 0)
    cplex = optimizer_with_attributes(CPLEX.Optimizer, "CPX_PARAM_SCRIND"=>0)
    if optimizer == :cplex 
        solver = cplex 
    elseif optimizer == :scip  
        solver = () -> scip
    else 
        error("unrecognized solver: solver can be either :cplex or :scip") 
    end 

    # solve model 
    result = optimize_model!(pm, optimizer = solver)

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

function write_json_output(output::NamedTuple)
    log_constant = output.log_constant
    result_ops = output.result_ops 
    risk_ops = output.risk_ops 
    result_eq_ops = output.result_eq_ops 
    risk_eq_ops = output.risk_eq_ops 
    demand = output.demand 
    served_ops = output.served_ops 
    served_eq_ops = output.served_eq_ops 
    risk_ub = output.risk_ub 
    in_file = output.file
    id = output.id
    
    folder_name = filter(x -> !(x in ["", "m", "data"]), split(in_file, ('.', '/'))) |> first
    folder_name = "./output/" * folder_name 

    (!isdir(folder_name)) && (mkdir(folder_name))
    instance_name = folder_name * "/" * string(id) * ".json"

    to_write = Dict{String,Any}(
        "log_constant" => log_constant, 
        "risk_upper_bound" => risk_ub,
        "risk_ops" => risk_ops, 
        "risk_equitable_ops" => risk_eq_ops, 
        "demand" => demand.demand, 
        "total_demand" => demand.total, 
        "load_served_ops" => served_ops.load_served, 
        "total_load_served_ops" => served_ops.total, 
        "load_served_equitable_ops" => served_eq_ops.load_served, 
        "total_load_served_equitable_ops" => served_eq_ops.total 
    )

    open(instance_name, "w") do f
        JSON.print(f, to_write, 4)
    end

end 

function main() 
    data = file |> get_data 
    modify_risk_weight(data, 0.2)
    pm = data |> get_ops_pm

    demand = compute_demand(pm)
    total_risk = pm |> compute_total_risk
    max_risk = 90.0
    num_points = 200

    for (i, risk_ub) in enumerate(range(0, max_risk; length = num_points))
        log_constant = 0.0001 
        modify_log_constant(data, log_constant)
        modify_risk_ub(data, risk_ub)
        pm_ops = data |> get_ops_pm 
        result_ops, risk_ops = solve_ops(pm_ops)
        served_ops = compute_load_served(result_ops)
        pm_eq_ops = data |> get_equitable_ops_pm 
        result_eq_ops, risk_eq_ops = solve_ops(pm_eq_ops; optimizer = :scip)
        served_eq_ops = compute_load_served(result_eq_ops)
        output = (
            log_constant = log_constant, 
            result_ops = result_ops, 
            risk_ops = risk_ops, 
            result_eq_ops = result_eq_ops, 
            risk_eq_ops = risk_eq_ops, 
            demand = demand, 
            served_ops = served_ops, 
            served_eq_ops = served_eq_ops, 
            risk_ub = risk_ub, 
            file = file,
            id = i
        )
        write_json_output(output)
        println("##### $risk_ub #####")
        @show risk_ops 
        @show risk_eq_ops
        @show log_constant
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





