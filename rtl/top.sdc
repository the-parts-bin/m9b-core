create_clock -name clk_osc -period 37.037 -waveform {0 18.518} [get_ports {ext_clk}]

// pll_main (see top.v): memory_clk = 27 * 16/3 = 144 MHz, system_clk =
// 72 MHz (PSRAM controller), 48 MHz / 4 = 12 MHz for the USB core. pll_hdmi: hdmi_bit_clk = 27 * 5 = 135 MHz, and the
// pixel clock (video, audio, CPU) = hdmi_bit_clk / 5 through a CLKDIV.
create_generated_clock -name clk_mem -source [get_ports {ext_clk}] -master_clock clk_osc -multiply_by 16 -divide_by 3 [get_pins {pll_main_instance/rpll_inst/CLKOUT}]
create_generated_clock -name clk_sys -source [get_ports {ext_clk}] -master_clock clk_osc -multiply_by 8 -divide_by 3 [get_pins {pll_main_instance/rpll_inst/CLKOUTD}]
// CPU: system_clk / 2 through a CLKDIV, in the same group as the PSRAM
// clocks: the bridge between the CPU and the controller is synchronous and
// timed (36 <-> 72 MHz paths get one 72 MHz period).
create_generated_clock -name clk_cpu -source [get_pins {pll_main_instance/rpll_inst/CLKOUTD}] -master_clock clk_sys -divide_by 2 [get_pins {cpu_div/CLKOUT}]
create_generated_clock -name clk_usb48 -source [get_ports {ext_clk}] -master_clock clk_osc -multiply_by 16 -divide_by 9 [get_pins {pll_main_instance/rpll_inst/CLKOUTD3}]
create_generated_clock -name clk_usb -source [get_pins {pll_main_instance/rpll_inst/CLKOUTD3}] -master_clock clk_usb48 -divide_by 4 [get_pins {usb_div/CLKOUT}]
create_generated_clock -name clk_hdmi_bit -source [get_ports {ext_clk}] -master_clock clk_osc -multiply_by 5 [get_pins {pll_hdmi_instance/rpll_inst/CLKOUT}]
create_generated_clock -name clk_pix -source [get_pins {pll_hdmi_instance/rpll_inst/CLKOUT}] -master_clock clk_hdmi_bit -divide_by 5 [get_pins {pixel_div/CLKOUT}]

// Unrelated groups: the oscillator itself (heartbeat LED only); the CPU
// and the PSRAM controller on pll_main; the USB clocks; the pixel clock and
// HDMI serializers on pll_hdmi (the two PLLs' output phases aren't related). Crossings
// between groups are synchronized (see soc.v, hyperram.sv, psram_bridge.v),
// so don't time them as synchronous.
set_clock_groups -asynchronous -group [get_clocks {clk_osc}] -group [get_clocks {clk_mem clk_sys clk_cpu}] -group [get_clocks {clk_usb48 clk_usb}] -group [get_clocks {clk_hdmi_bit clk_pix}]

// Reports. Custom report_timing commands replace Gowin's default one (the
// 25 worst setup paths overall), so it is repeated first.
report_timing -setup -max_paths 40 -max_common_paths 1
// The CPU's own paths, and its crossings with the PSRAM controller.
report_timing -setup -max_paths 60 -max_common_paths 1 -from_clock [get_clocks {clk_cpu}] -to_clock [get_clocks {clk_cpu}]
report_timing -setup -max_paths 20 -max_common_paths 1 -from_clock [get_clocks {clk_cpu}] -to_clock [get_clocks {clk_sys}]
report_timing -setup -max_paths 20 -max_common_paths 1 -from_clock [get_clocks {clk_sys}] -to_clock [get_clocks {clk_cpu}]

// The PSRAM controller's reset to the I/O serializers (OSER4/IDES4 RESET,
// timed against the 144 MHz falling edge): released once at startup, and
// the controller waits ~200 us before using the PSRAM.
set_false_path -from [get_regs {soc_instance/hyperram_instance/rst_s0}] -to [get_clocks {clk_mem}]
