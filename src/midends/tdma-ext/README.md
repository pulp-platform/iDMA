# 4D Tensor DMA Frontend

This is the home of the TDMA frontend. (Not yet ready to be integrated - will be part of the new channel-based DMA included in PULP)

## Evaluate me
- Open `test/tdma_fe_tb` and program the frontend.
- Shape is the granularity - 1 is byte-granularity, 4 is 32 bit granularity
- A stride and / or size of zero deactivates the stage, if size == 1, set both strides to 1 as well.
- Compile in `vsim` folder (`compile.tcl`)
- Start modelsim in `vsim` folder (`start.tcl`)
- Run simulation: `run -all`

