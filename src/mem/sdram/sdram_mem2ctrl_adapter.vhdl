-- EMACS settings: -*-  tab-width: 2; indent-tabs-mode: t -*-
-- vim: tabstop=2:shiftwidth=2:noexpandtab
-- kate: tab-width 2; replace-tabs off; indent-width 2;
-- 
-- ============================================================================
-- Authors:					Martin Zabel
-- 
-- Module:					Adapter between PoC.Mem and SDRAM controller interface.
--
-- Description:
-- ------------------------------------
-- Adapter between the :ref:`PoC.Mem <INT:PoC.Mem>` interface and the
-- user interface ("user") of the PoC SDRAM controller.
-- (Extracted from memtest_qm_xc6slx16_sdram.vhdl within PoC-Examples.)
--
-- All accesses are word-aligned on the PoC.Mem interface.
--
-- Generic parameters:
--
-- * MEM_A_BITS: Address bus width of the PoC.Mem interface.
--
-- * MEM_D_BITS: Data bus width of the PoC.Mem interface.
--
-- * RATIO: Data bus width ratio between PoC.Mem interface and controller interface.
--   Must be a multiple of 2.
--
-- Derived controller data bus width = MEM_D_BITS / RATIO.
--
-- Derived controller address bus width = MEM_A_BITS + log_2(RATIO).
--
-- clk_sys / rst_sys: System clock & reset associated with mem_* interface.
-- clk_ctrl / rst_ctrl: Memory controller clock & reset associated with
--   user_* interface. 
--
-- Cross-clock FIFOs are included. clk_sys and clk_ctrl can be unrelated.
--
-- License:
-- ============================================================================
-- Copyright 2020      Martin Zabel, Berlin, Germany
-- Copyright 2007-2015 Technische Universitaet Dresden - Germany,
--										 Chair for VLSI-Design, Diagnostics and Architecture
-- 
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
-- 
--		http://www.apache.org/licenses/LICENSE-2.0
-- 
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- ============================================================================


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library poc;
use poc.utils.all;

entity sdram_mem2ctrl_adapter is

	generic (
		MEM_A_BITS : positive;
		MEM_D_BITS : positive;
		RATIO : positive := 1
	);

  port (
    clk_sys  : in std_logic;
    clk_ctrl : in std_logic;
    rst_sys  : in std_logic;
    rst_ctrl : in std_logic;

    -- PoC.Mem interface
    mem_req   : in  std_logic;
    mem_write : in  std_logic;
    mem_addr  : in  unsigned(MEM_A_BITS-1 downto 0);
    mem_wdata : in  std_logic_vector(MEM_D_BITS-1 downto 0);
    mem_wmask : in  std_logic_vector(MEM_D_BITS/8-1 downto 0) := (others => '0');
    mem_rdy   : out std_logic;
    mem_rstb  : out std_logic;
    mem_rdata : out std_logic_vector(MEM_D_BITS-1 downto 0);

		-- SDRAM controller user's interface
    user_cmd_valid   : out std_logic;
    user_wdata_valid : out std_logic;
    user_write       : out std_logic;
    user_addr        : out std_logic_vector(MEM_A_BITS+log2ceil(RATIO)-1 downto 0);
    user_wdata       : out std_logic_vector(MEM_D_BITS/RATIO-1 downto 0);
    user_wmask       : out std_logic_vector(MEM_D_BITS/RATIO/8-1 downto 0);
    user_got_cmd     : in  std_logic;
    user_got_wdata   : in  std_logic;
    user_rdata       : in  std_logic_vector(MEM_D_BITS/RATIO-1 downto 0);
    user_rstb        : in  std_logic);

end sdram_mem2ctrl_adapter;

architecture rtl of sdram_mem2ctrl_adapter is

	constant CTRL_A_BITS : positive := MEM_A_BITS+log2ceil(RATIO);
	constant CTRL_D_BITS : positive := MEM_D_BITS/RATIO;
	constant CTRL_M_BITS : positive := MEM_D_BITS/RATIO/8;
	
  signal cf_put   : std_logic;
  signal cf_full  : std_logic;
  signal cf_din   : std_logic_vector(MEM_A_BITS+1-1 downto 0);
  signal cf_dout  : std_logic_vector(MEM_A_BITS+1-1 downto 0);
  signal cf_valid : std_logic;
  signal cf_got   : std_logic;

  signal wf_put   : std_logic;
  signal wf_full  : std_logic;
  signal wf_din   : std_logic_vector(MEM_D_BITS/8+MEM_D_BITS-1 downto 0);
  signal wf_dout  : std_logic_vector(MEM_D_BITS/8+MEM_D_BITS-1 downto 0);
  signal wf_valid : std_logic;
  signal wf_got   : std_logic;

  signal rf_put   : std_logic;
  signal rf_din   : std_logic_vector(MEM_D_BITS-1 downto 0);
  signal rf_got   : std_logic;
  signal rf_dout  : std_logic_vector(MEM_D_BITS-1 downto 0);

	-- internal version of output signals
	signal mem_rdy_i : std_logic;
	
begin  -- rtl

  cmd_fifo: entity PoC.fifo_ic_got
    generic map (
      DATA_REG  => true,
      D_BITS    => MEM_A_BITS+1,
      MIN_DEPTH => 8)
    port map (
      clk_wr => clk_sys,
      rst_wr => rst_sys,
      put    => cf_put,
      din    => cf_din,
      full   => cf_full,
      clk_rd => clk_ctrl,
      rst_rd => rst_ctrl,
      got    => cf_got,
      valid  => cf_valid,
      dout   => cf_dout);

  wr_fifo: entity PoC.fifo_ic_got
    generic map (
      DATA_REG  => true,
      D_BITS    => MEM_D_BITS/8+MEM_D_BITS,
      MIN_DEPTH => 8)
    port map (
      clk_wr => clk_sys,
      rst_wr => rst_sys,
      put    => wf_put,
      din    => wf_din,
      full   => wf_full,
      clk_rd => clk_ctrl,
      rst_rd => rst_ctrl,
      got    => wf_got,
      valid  => wf_valid,
      dout   => wf_dout);

  -- The size of this FIFO depends on the latency between write and read
  -- clock domain
  rd_fifo: entity PoC.fifo_ic_got
    generic map (
      DATA_REG  => true,
      D_BITS    => MEM_D_BITS,
      MIN_DEPTH => 8)
    port map (
      clk_wr => clk_ctrl,
      rst_wr => rst_ctrl,
      put    => rf_put,
      din    => rf_din,
      full   => open,                   -- can't stall
      clk_rd => clk_sys,
      rst_rd => rst_sys,
      got    => rf_got,
      valid  => rf_got,
      dout   => rf_dout);

  -- Signal mem_rdy only if both FIFOs are not full.
  mem_rdy_i <= cf_full nor wf_full;
  mem_rdy   <= mem_rdy_i;

  -- Word aligned access to memory.
  -- Parallel "put" to both FIFOs.
  cf_put <= mem_req and mem_rdy_i;
  wf_put <= mem_req and mem_write and mem_rdy_i;
  cf_din <= mem_write & std_logic_vector(mem_addr);
  wf_din <= mem_wmask & mem_wdata;

	-- Read-data from FIFO
  mem_rstb  <= rf_got;
  mem_rdata <= rf_dout;

	-- FIFO mapping on controller side
  user_cmd_valid   <= cf_valid;
  user_wdata_valid <= wf_valid;
  user_write       <= cf_dout(cf_dout'left);

  gRatioEq1 : if RATIO = 1 generate
    user_addr  <= cf_dout(cf_dout'left-1 downto 0);
    user_wdata <= wf_dout(MEM_D_BITS-1 downto 0);
    user_wmask <= wf_dout(wf_dout'left downto MEM_D_BITS);
    cf_got     <= user_got_cmd;
    wf_got     <= user_got_wdata;
    rf_din     <= user_rdata;
    rf_put     <= user_rstb;
  end generate;

	gRatioGt1 : if RATIO > 1 generate
		signal wf_data : std_logic_vector(MEM_D_BITS-1 downto 0);
		signal wf_mask : std_logic_vector(MEM_D_BITS/8-1 downto 0);
		signal wdata_r : std_logic_vector((RATIO-1)*CTRL_D_BITS-1 downto 0);
		signal wmask_r : std_logic_vector((RATIO-1)*CTRL_M_BITS-1 downto 0);
		signal wcnt_r  : unsigned(log2ceil(RATIO)-1 downto 0);
		signal rdata_r : std_logic_vector((RATIO-1)*CTRL_D_BITS-1 downto 0);
		signal rcnt_r  : unsigned(log2ceil(RATIO)-1 downto 0);
	begin
		-- vector decomposition
		wf_data <= wf_dout(MEM_D_BITS-1 downto 0);
		wf_mask <= wf_dout(wf_dout'left downto MEM_D_BITS);

		-- command
		user_addr <= cf_dout(cf_dout'left-1 downto 0) & (log2ceil(RATIO)-1 downto 0 => '0');
    cf_got    <= user_got_cmd;

		-- Write data side:
		-- The lower CTRL_D_BITS are directly transfered to the controller.
		-- The upper bits are taken from a shift register.
		user_wdata <= wf_data(CTRL_D_BITS-1 downto 0) when wcnt_r = 0 else
									wdata_r(CTRL_D_BITS-1 downto 0);
		user_wmask <= wf_mask(CTRL_M_BITS-1 downto 0) when wcnt_r = 0 else
									wmask_r(CTRL_M_BITS-1 downto 0);
    wf_got     <= user_got_wdata when wcnt_r = 0 else '0';
		
		process(clk_ctrl)
		begin
			if rising_edge(clk_ctrl) then
				if user_got_wdata = '1' then
					if wcnt_r = 0 then
						-- The lower CTRL_D_BITS are directly transfered to the controller.
						-- Only the upper bits must be saved for future clock cycles.
						wdata_r <= wf_data(MEM_D_BITS-1 downto CTRL_D_BITS);
						wmask_r <= wf_mask(MEM_D_BITS/8-1 downto CTRL_M_BITS);
					else
						-- Shift right.
						wdata_r <= (CTRL_D_BITS-1 downto 0 => '0') & wdata_r(wdata_r'left downto CTRL_D_BITS);
						wmask_r <= (CTRL_M_BITS-1 downto 0 => '0') & wmask_r(wmask_r'left downto CTRL_M_BITS);
					end if;
				end if;

				if rst_ctrl = '1' then
					wcnt_r <= (others => '0');
				elsif user_got_wdata = '1' then
					-- wrapping counter
					wcnt_r <= wcnt_r + 1;
				end if;
			end if;
		end process;

		-- Read data side:
		-- Read data from controller is stored in shift register first, except last
		-- controller word. Push to Read FIFO when last controller word is received.
		rf_din <= user_rdata & rdata_r;
		rf_put <= '1' when rcnt_r = (rcnt_r'range => '1') and (user_rstb = '1') else '0';
		
		process(clk_ctrl)
		begin
			if rising_edge(clk_ctrl) then
				if user_rstb = '1' then
					-- Shift right.
					rdata_r <= user_rdata & rdata_r(rdata_r'left downto CTRL_D_BITS); 
				end if;
				
				if rst_ctrl = '1' then
					rcnt_r   <= (others => '0');
				elsif user_rstb = '1' then
					rcnt_r <= rcnt_r + 1;
				end if;
			end if;
		end process;
	end generate;

end rtl;