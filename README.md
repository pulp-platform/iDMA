# iDMA
[![GitHub tag (latest SemVer)](https://img.shields.io/github/v/tag/pulp-platform/iDMA?color=blue&label=current&sort=semver)](CHANGELOG.md)
[![SHL-0.51 license](https://img.shields.io/badge/license-SHL--0.51-green)](LICENSE)

Home of the iDMA - a modular, parametrizable, and highly flexible *Data Movement Accelerator (DMA)*
architecture targeting a wide range of platforms from ultra-low power edge nodes to high-performance
computing systems. iDMA is part of the [PULP (Parallel Ultra-Low-Power) platform](https://pulp-platform.org/),
where it is used as a cluster level DMA in the [Snitch Cluster](https://github.com/pulp-platform/snitch)
and in the [PULP Cluster](https://github.com/pulp-platform/pulp).

iDMA currently implements AXI4[+ATOPs from AXI5](https://github.com/pulp-platform/axi).

## Modular Architecture
iDMA is centered around the idea to split the DMA engine in 3 distinct parts:
- **Frontend:** The frontend implements the communication with the platform and emits transfer requests
- **Midend:** Midend(s) transform a transfer request from the frontend to generic 1D transfers,
              which can be handled by the backend.
- **Bakend:** The backend gets a 1D transfer `(src_addr, dst_addr, length)` and executes it
              on the AXI4 manager interface.

The interface between the parts are well-defined, making it easy to adapt to a new system or to add
new capabilities.

## Documentation
The [latest documentation](https://pulp-platform.github.io/iDMA) can be accessed pre-built.
The [Morty docs](https://pulp-platform.github.io/iDMA/morty/index.html) provide the generated description of the SystemVerilog files within this repository.

## License
iDMA is released under Solderpad v0.51 (SHL-0.51) see [`LICENSE`](LICENSE):

## Contributing
We are happy to accept pull requests and issues from any contributors. See [`CONTRIBUTING.md`](CONTRIBUTING.md)
for additional information.

## Getting Started

### Prerequisites
iDMA can directly be integrated after cloning it from this repository. However, to regenerate
the configuration registers, build the documentation, and run various checks on the source code,
various tools are required.

- [`bender >= v0.24.0`](https://github.com/pulp-platform/bender)
- [`morty >= v0.6.0`](https://github.com/zarubaf/morty)
- [`Verilator = v4.202`](https://www.veripool.org/verilator)
- [`Verible >= v0.0-1051-gd4cd328`](https://github.com/chipsalliance/verible)
- `Python3 >= 3.8` including some the libraries listed in [`requirements.txt`](requirements.txt)

### Building the Documentation
Use `make doc` to build the documentation. The output is located at `doc/build`.


### Simulation
We currently do not include any free and open-source simulation setup. However, if you have access to
[*Questa advanced simulator*](https://eda.sw.siemens.com/en-US/ic/questa/simulation/advanced-simulator/),
a simulation can be launched using:

```
make prepare_sim
vsim -c -do "source scripts/compile_vsim.tcl; quit"
vsim -c -t 1ps -voptargs=+acc \
     +job_file=jobs/backend/man_simple.txt \
     -logfile logs/backend.simple.vsim.log
     -wlf logs/backend.simple.wlf \
     tb_idma_backend \
     -do "source scripts/start_vsim.tcl; run -all"
```

Where:
- `+job_file=jobs/backend/man_simple.txt` can point to any valid [job file](jobs/README.md)
- `-logfile logs/backend.simple.vsim.log` denotes the log file
- `-wlf logs/backend.simple.wlf` specifies a wave file
- `tb_idma_backend` can be any of the supplied testbenches \(`test/tb_idma_*`\)
