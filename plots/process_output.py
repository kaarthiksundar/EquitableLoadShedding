
import os 
from natsort import natsorted 
import json 
import csv


def main(): 
    process_rts_gmlc_risk_output()

def process_rts_gmlc_risk_output(): 
    folder = '../git-output/RTS_GMLC_risk/'
    files = natsorted(os.listdir(folder), key=lambda y: y.lower())
    csv_ops = [] 
    csv_eq_ops = []
    header = [] 
    
    for file in files: 
        f = open(folder + file)
        data = json.load(f)
        if len(header) == 0:
            header += ['ub', 'risk', 'ls']
        ops = [
            data['risk_upper_bound'], 
            data['risk_ops'], 
            data['total_demand'] - data['total_load_served_ops']
        ]
        eq_ops = [
            data['risk_upper_bound'], 
            data['risk_equitable_ops'], 
            data['total_demand'] - data['total_load_served_equitable_ops']
        ]
        demand = data['demand']
        load_served_ops = data['load_served_ops']
        load_served_eq_ops = data['load_served_equitable_ops']
        load_ids = natsorted(demand.keys(), key=lambda y: y.lower())
        if len(header) == 3:
            header += load_ids
        for id in load_ids:
            shed = demand[id] - load_served_ops.get(id, 0.0)
            eq_shed = demand[id] - load_served_eq_ops.get(id, 0.0)
            ops.append(shed)
            eq_ops.append(eq_shed)
        csv_ops.append(ops)
        csv_eq_ops.append(eq_ops)
    

    with open("rts_gmlc_risk_ops.csv", "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(csv_ops)
        
    with open("rts_gmlc_risk_eq_ops.csv", "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(csv_eq_ops)
    

if __name__ == "__main__":
    main()