#!/bin/bash

JOB_DIR="../../jobs/backend_rw_axi/"
JOB_FILES="$JOB_DIR"*.yml

for file in $JOB_FILES; do
    echo "Running test $file"
    ./obj_dir/tb_idma "$file" >/dev/null
done
