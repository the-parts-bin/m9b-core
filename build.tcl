open_project core.gprj
# Higher-effort place & route (the defaults, 0/0, miss timing). Place
# options 1/2/3 give the same result, as do 0 and 4: two placements to
# choose from when a change misses timing by a little; the route options
# differ by several MHz from build to build (README.md, Clocks: Timing).
set_option -place_option 0
set_option -route_option 2
# The on-board SPI flash sits on the MSPI configuration pins (59-62): use
# them as ordinary I/O once configured (the FPGA boots from its internal
# flash, not from this one).
set_option -use_mspi_as_gpio 1
run all
