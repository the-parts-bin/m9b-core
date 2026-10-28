open_project bsram_be.gprj
set_option -top_module bsram_be
set_option -place_option 1
set_option -route_option 2
# where each BSRAM instance went (impl/pnr/bsram_be.posp)
set_option -gen_posp 1
run all
