# iDMA

Home of the DMA. Replaces the version on `github.com/axi`!!!!

## Build for Simulation
`sh> make sim_all`


## Simulate
`sh> vsim -64 &` \
`vsim> source scripts/compile.tcl` \
`vsim> source scripts/start.tcl` \
`vsim> run -all`


### Trace
`sh> make trace`

## Docs
Requires a morty installation for full functionality (See https://github.com/zarubaf/morty)
`make -C doc clean morty-docs html`


### CVA6 Integration (build, minimal driver and simulation)
Please have a look at the tutorial in [driver/cva6/README](driver/cva6/README.md)
