import os
import yaml
from collections import Counter

JOBS_DIR = "./backend_rw_axi"

for filename in os.listdir(JOBS_DIR):
    file_path = os.path.join(JOBS_DIR, filename)

    if ".txt" in file_path and os.path.isfile(file_path):
        print(f"Processing file: {file_path}")
        file_dict = {"defaults": {}, "jobs": []}

        with open(file_path, "r") as file:
            lines = file.readlines()
            num_lines = len(lines)

            i = 0
            while i < num_lines:
                chunk = [int(line.strip(), 0) for line in lines[i:i+10]]
                chunk_dict = {
                    "length": chunk[0],
                    "src_addr": chunk[1],
                    "dst_addr": chunk[2],
                    "src": chunk[3],
                    "dst": chunk[4],
                    "src_max_llen": chunk[5],
                    "dst_max_llen": chunk[6],
                    "decouple_raw": chunk[7],
                    "decouple_rw": chunk[8]
                }
                num_errors = chunk[9]
                    
                if num_errors > 0:
                    chunk_dict["errors"] = [line.strip() for line in lines[i+10:i+10+num_errors]]
                    i += num_errors
                file_dict["jobs"].append(chunk_dict)
                i += 10

            # Put common options in the defaults

            for k in chunk_dict:
                if k not in ["length", "src_addr", "dst_addr", "errors"]:
                    file_dict["defaults"][k] = Counter([job[k] for job in file_dict["jobs"]]).most_common(1)[0][0]

            for job in file_dict["jobs"]:
                for k in file_dict["defaults"]:
                    if job[k] == file_dict["defaults"][k]:
                        del job[k]

            # Save as YAML

            yaml_filename = filename.replace(".txt", ".yml")
            yaml_path = os.path.join(JOBS_DIR, yaml_filename)
            with open(yaml_path, "w") as yaml_file:
                yaml.dump(file_dict, yaml_file, sort_keys=False)
