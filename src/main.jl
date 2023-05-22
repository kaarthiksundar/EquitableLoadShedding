using PowerModels, PowerModelsWildfire
using JuMP, SCIP, CPLEX 

scip = JuMP.optimizer_with_attributes(SCIP.Optimizer)
cplex = JuMP.optimizer_with_attributes(CPLEX.Optimizer)

file = "./data/RTS_GMLC_risk.m"

data = PowerModels.parse_file(file)

results = PowerModelsWildfire.run_ops(data, PowerModels.DCPPowerModel, cplex)