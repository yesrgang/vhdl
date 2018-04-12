library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_misc.all;
use ieee.std_logic_unsigned.all;
use work.frontpanel.all;

entity digital_sequencer is
	port (
        -- opal kelly --
		hi_in     : in    std_logic_vector(7 downto 0);
		hi_out    : out   std_logic_vector(1 downto 0);
		hi_inout  : inout std_logic_vector(15 downto 0);
		hi_muxsel : out   std_logic;
		-- ok peripherals --
        led    : out   std_logic_vector(7 downto 0);
		-- 100 MHz from PLL --
		clk_100 : in std_logic;	
        -- external trigger --
        trigger : in std_logic;
        -- sequence out --
        logic_out : inout std_logic_vector(63 downto 0) := (others => '0')
	);
end digital_sequencer;

architecture arch of digital_sequencer is
    -- opal kelly --
    signal ti_clk   : std_logic; -- 48MHz clk. USB data is sync'd to this.
	signal ok1      : std_logic_vector(30 downto 0);
	signal ok2      : std_logic_vector(16 downto 0);
	signal ok2s     : std_logic_vector(17*2-1 downto 0);
    -- ok usb --
	signal ep00wire : std_logic_vector(15 downto 0);
    signal ep01wire : std_logic_vector(15 downto 0);
    signal ep02wire : std_logic_vector(15 downto 0);
    signal ep03wire : std_logic_vector(15 downto 0);
    signal ep04wire : std_logic_vector(15 downto 0);
    signal ep05wire : std_logic_vector(15 downto 0);
    signal ep06wire : std_logic_vector(15 downto 0);
    signal ep07wire : std_logic_vector(15 downto 0);
    signal ep08wire : std_logic_vector(15 downto 0);
	signal ep20wire : std_logic_vector(15 downto 0);
	signal ep60trig : std_logic_vector(15 downto 0);
    signal ep80pipe  : std_logic_vector(15 downto 0); 
    signal ep80write : std_logic; -- hi during communication
   
    type state_type is (idle, load, run); --global state types
    signal state : state_type := idle; --global state
    
    signal ticks_til_update : integer := 10;
    signal sequence_count   : integer range 0 to 1000 := 0;
    signal sequence_logic   : std_logic_vector(63 downto 0) := (others => '0') ;
    signal sequence_finished : std_logic; -- goes high when sequence is done (ram reads 0)

    signal clk     : std_logic;
    signal slo_clk : std_logic;
    signal clk_50  : std_logic := '0';
    
    -- ram --
    signal ram_clk     : std_logic;
    signal ram_we      : std_logic;
    signal ram_addr    : integer range 0 to 24000 := 0; -- update ram_data_depth too!!
    signal ram_data_i  : std_logic_vector(15 downto 0);
    signal ram_data_o  : std_logic_vector(15 downto 0);

    component ram
    generic(
        data_depth : integer;
        data_width : integer
    );
    port(
        clock         : in std_logic;
        we            : in std_logic;
        address       : in integer range 0 to data_depth - 1;
        data_i        : inout std_logic_vector(data_width - 1 downto 0);
        data_o        : out std_logic_vector(data_width - 1 downto 0)
    );
    end component;

begin

hi_muxsel <= '0'; -- ok says so...
clk <= ti_clk when (state = load) else
       clk_50; -- 100MHz clock causes channels 56-63 to be glitchy
ram_clk <= clk;
--led(7) <= slo_clk;

ep60trig <= ("000000000000000" & sequence_finished);

--    --slo_clk
--    process (clk_100) is --it blinks twice a second. 
--        variable counter : integer := 0;
--    begin
--        if rising_edge(clk_100) then
--            counter := counter + 1;
--            if counter < 25000000 then
--                slo_clk <= '0';
--            elsif counter < 50000000 then
--                slo_clk <= '1';
--            elsif counter >= 50000000 then
--                counter := 0;
--            end if;
--        end if;
--    end process;
    
    process (clk_100) is 
    begin 
        if rising_edge(clk_100) then
            clk_50 <= not clk_50;
        end if;
    end process;
        
    --control state with ep00wrire
    process (ep00wire, clk_100) is
    begin
        if rising_edge(clk_100) then --trigger state change on clk
            if ep00wire(1 downto 0) = "00" then
                state <= idle;
            elsif ep00wire(1 downto 0) = "01" then
                state <= load;
            elsif ep00wire(1 downto 0) = "10" then
                state <= run;
            end if;
        end if;
    end process;

    --control ram_data_i, ram_we
    process (clk, state, ep80write, ep80pipe) is
    begin
        if falling_edge(clk) then
            case (state) is
                when load => --load data from ep80pipe (USB) into ram
                    if ep80write = '1' then 
                        ram_we <= '1'; -- ep80wire goes hi for 1 ti_clk cycle if ep80pipe has been updated.
                    else 
                        ram_we <= '0';
                    end if;
                    ram_data_i <= ep80pipe(15 downto 0);
                when others => null;
            end case;
        end if;
    end process;

    -- control sequence_logic, 
    process(clk, state, ram_data_o, sequence_finished, trigger) is
        variable read_logic : std_logic_vector(95 downto 0) := conv_std_logic_vector(0, 96); -- holds data read from ram.
        variable armed : std_logic := '0';
        variable waiting_trigger : std_logic := '0';
        variable read_ticks : integer;
    begin
        if falling_edge(clk) then
            -- led(7 downto 0) <= not sequence_logic(63 downto 56);
            --led <= not (sequence_finished & "000000" & trigger);
--            led <= not conv_std_logic_vector(ticks_til_update, 8);
            led <= not (trigger & "00000" & waiting_trigger & armed);
            case(state) is
                when load => -- get ready to run, output defaults
                    sequence_finished <= '0';
                when idle => -- get ready to run, output defaults
                    ticks_til_update <= 100; 
                    sequence_count <= 0;
                    sequence_finished <= '0';
                when run => 
                    if ticks_til_update < 0 then -- something changes, we are adding 10 ns at each switch
                        read_ticks := conv_integer(read_logic(95 downto 64));
                        if read_ticks = 0 then -- the sequence is done. start over
                            sequence_finished <= '1';
                        elsif read_ticks = 2**31 - 1 then
                            waiting_trigger := '1';
                            sequence_logic <= read_logic(63 downto 0);
                            ticks_til_update <= 40;
                            sequence_count <= sequence_count + 1;
                        else -- update outputs and ticks til next update
                            sequence_logic <= read_logic(63 downto 0);
                            ticks_til_update <= read_ticks - 2;
                            sequence_count <= sequence_count + 1;
--                            sequence_finished <= '0';
                        end if;
                    elsif waiting_trigger = '1' then
                        if (trigger = '1') and (armed = '1') then
                            ticks_til_update <= 40;
                            armed := '0';
                            waiting_trigger := '0';
                        elsif trigger = '0' then
                            armed := '1';
                        end if;
                    else  -- tick
                        ticks_til_update <= ticks_til_update - 1;
                        if ticks_til_update < 6 then -- need to read from ram
                            read_logic((ticks_til_update + 1) * 16 - 1 downto (ticks_til_update) * 16) := ram_data_o;
                        end if;
--                       sequence_finished <= '0';
                    end if;
                when others => null;
            end case;
        end if;
    end process;

    -- control ram_addr
    process (clk, state, ep80write) is
    begin
        if rising_edge(clk) then
            case (state) is
                when load => 
                    if ep80write = '1' then -- advance ram_addr every time we write to the ram
                        ram_addr <= ram_addr + 1;
                    end if;
                when run => 
                    if ticks_til_update < 7 then -- read backwards. two timing words, then four logic words.
                        ram_addr <= sequence_count*6 + ticks_til_update-1;
                    else ram_addr <= (sequence_count)*6+5;
                    end if;
                when others =>
                    ram_addr <= 0;
            end case;
        end if;
    end process;

    logic_out(0) <= sequence_logic(0) when (ep01wire(0)='0' and ep02wire(0)='0') else
                    not sequence_logic(0) when (ep01wire(0)='0' and ep02wire(0)='1') else
                    ep02wire(0);
    logic_out(1) <= sequence_logic(1) when (ep01wire(1)='0' and ep02wire(1)='0') else
                    not sequence_logic(1) when (ep01wire(1)='0' and ep02wire(1)='1') else
                    ep02wire(1);
    logic_out(2) <= sequence_logic(2) when (ep01wire(2)='0' and ep02wire(2)='0') else
                    not sequence_logic(2) when (ep01wire(2)='0' and ep02wire(2)='1') else
                    ep02wire(2);
    logic_out(3) <= sequence_logic(3) when (ep01wire(3)='0' and ep02wire(3)='0') else
                    not sequence_logic(3) when (ep01wire(3)='0' and ep02wire(3)='1') else
                    ep02wire(3);
    logic_out(4) <= sequence_logic(4) when (ep01wire(4)='0' and ep02wire(4)='0') else
                    not sequence_logic(4) when (ep01wire(4)='0' and ep02wire(4)='1') else
                    ep02wire(4);
    logic_out(5) <= sequence_logic(5) when (ep01wire(5)='0' and ep02wire(5)='0') else
                    not sequence_logic(5) when (ep01wire(5)='0' and ep02wire(5)='1') else
                    ep02wire(5);
    logic_out(6) <= sequence_logic(6) when (ep01wire(6)='0' and ep02wire(6)='0') else
                    not sequence_logic(6) when (ep01wire(6)='0' and ep02wire(6)='1') else
                    ep02wire(6);
    logic_out(7) <= sequence_logic(7) when (ep01wire(7)='0' and ep02wire(7)='0') else
                    not sequence_logic(7) when (ep01wire(7)='0' and ep02wire(7)='1') else
                    ep02wire(7);
    logic_out(8) <= sequence_logic(8) when (ep01wire(8)='0' and ep02wire(8)='0') else
                    not sequence_logic(8) when (ep01wire(8)='0' and ep02wire(8)='1') else
                    ep02wire(8);
    logic_out(9) <= sequence_logic(9) when (ep01wire(9)='0' and ep02wire(9)='0') else
                    not sequence_logic(9) when (ep01wire(9)='0' and ep02wire(9)='1') else
                    ep02wire(9);
    logic_out(10) <= sequence_logic(10) when (ep01wire(10)='0' and ep02wire(10)='0') else
                    not sequence_logic(10) when (ep01wire(10)='0' and ep02wire(10)='1') else
                    ep02wire(10);
    logic_out(11) <= sequence_logic(11) when (ep01wire(11)='0' and ep02wire(11)='0') else
                    not sequence_logic(11) when (ep01wire(11)='0' and ep02wire(11)='1') else
                    ep02wire(11);
    logic_out(12) <= sequence_logic(12) when (ep01wire(12)='0' and ep02wire(12)='0') else
                    not sequence_logic(12) when (ep01wire(12)='0' and ep02wire(12)='1') else
                    ep02wire(12);
    logic_out(13) <= sequence_logic(13) when (ep01wire(13)='0' and ep02wire(13)='0') else
                    not sequence_logic(13) when (ep01wire(13)='0' and ep02wire(13)='1') else
                    ep02wire(13);
    logic_out(14) <= sequence_logic(14) when (ep01wire(14)='0' and ep02wire(14)='0') else
                    not sequence_logic(14) when (ep01wire(14)='0' and ep02wire(14)='1') else
                    ep02wire(14);
    logic_out(15) <= sequence_logic(15) when (ep01wire(15)='0' and ep02wire(15)='0') else
                    not sequence_logic(15) when (ep01wire(15)='0' and ep02wire(15)='1') else
                    ep02wire(15);
    
    logic_out(16) <= sequence_logic(16) when (ep03wire(0)='0' and ep04wire(0)='0') else
                    not sequence_logic(16) when (ep03wire(0)='0' and ep04wire(0)='1') else
                    ep04wire(0);
    logic_out(17) <= sequence_logic(17) when (ep03wire(1)='0' and ep04wire(1)='0') else
                    not sequence_logic(17) when (ep03wire(1)='0' and ep04wire(1)='1') else
                    ep04wire(1);
    logic_out(18) <= sequence_logic(18) when (ep03wire(2)='0' and ep04wire(2)='0') else
                    not sequence_logic(18) when (ep03wire(2)='0' and ep04wire(2)='1') else
                    ep04wire(2);
    logic_out(19) <= sequence_logic(19) when (ep03wire(3)='0' and ep04wire(3)='0') else
                    not sequence_logic(19) when (ep03wire(3)='0' and ep04wire(3)='1') else
                    ep04wire(3);
    logic_out(20) <= sequence_logic(20) when (ep03wire(4)='0' and ep04wire(4)='0') else
                    not sequence_logic(20) when (ep03wire(4)='0' and ep04wire(4)='1') else
                    ep04wire(4);
    logic_out(21) <= sequence_logic(21) when (ep03wire(5)='0' and ep04wire(5)='0') else
                    not sequence_logic(21) when (ep03wire(5)='0' and ep04wire(5)='1') else
                    ep04wire(5);
    logic_out(22) <= sequence_logic(22) when (ep03wire(6)='0' and ep04wire(6)='0') else
                    not sequence_logic(22) when (ep03wire(6)='0' and ep04wire(6)='1') else
                    ep04wire(6);
    logic_out(23) <= sequence_logic(23) when (ep03wire(7)='0' and ep04wire(7)='0') else
                    not sequence_logic(23) when (ep03wire(7)='0' and ep04wire(7)='1') else
                    ep04wire(7);
    logic_out(24) <= sequence_logic(24) when (ep03wire(8)='0' and ep04wire(8)='0') else
                    not sequence_logic(24) when (ep03wire(8)='0' and ep04wire(8)='1') else
                    ep04wire(8);
    logic_out(25) <= sequence_logic(25) when (ep03wire(9)='0' and ep04wire(9)='0') else
                    not sequence_logic(25) when (ep03wire(9)='0' and ep04wire(9)='1') else
                    ep04wire(9);
    logic_out(26) <= sequence_logic(26) when (ep03wire(10)='0' and ep04wire(10)='0') else
                    not sequence_logic(26) when (ep03wire(10)='0' and ep04wire(10)='1') else
                    ep04wire(10);
    logic_out(27) <= sequence_logic(27) when (ep03wire(11)='0' and ep04wire(11)='0') else
                    not sequence_logic(27) when (ep03wire(11)='0' and ep04wire(11)='1') else
                    ep04wire(11);
    logic_out(28) <= sequence_logic(28) when (ep03wire(12)='0' and ep04wire(12)='0') else
                    not sequence_logic(28) when (ep03wire(12)='0' and ep04wire(12)='1') else
                    ep04wire(12);
    logic_out(29) <= sequence_logic(29) when (ep03wire(13)='0' and ep04wire(13)='0') else
                    not sequence_logic(29) when (ep03wire(13)='0' and ep04wire(13)='1') else
                    ep04wire(13);
    logic_out(30) <= sequence_logic(30) when (ep03wire(14)='0' and ep04wire(14)='0') else
                    not sequence_logic(30) when (ep03wire(14)='0' and ep04wire(14)='1') else
                    ep04wire(14);
    logic_out(31) <= sequence_logic(31) when (ep03wire(15)='0' and ep04wire(15)='0') else
                    not sequence_logic(31) when (ep03wire(15)='0' and ep04wire(15)='1') else
                    ep04wire(15);
    
    logic_out(32) <= sequence_logic(32) when (ep05wire(0)='0' and ep06wire(0)='0') else
                    not sequence_logic(32) when (ep05wire(0)='0' and ep06wire(0)='1') else
                    ep06wire(0);
    logic_out(33) <= sequence_logic(33) when (ep05wire(1)='0' and ep06wire(1)='0') else
                    not sequence_logic(33) when (ep05wire(1)='0' and ep06wire(1)='1') else
                    ep06wire(1);
    logic_out(34) <= sequence_logic(34) when (ep05wire(2)='0' and ep06wire(2)='0') else
                    not sequence_logic(34) when (ep05wire(2)='0' and ep06wire(2)='1') else
                    ep06wire(2);
    logic_out(35) <= sequence_logic(35) when (ep05wire(3)='0' and ep06wire(3)='0') else
                    not sequence_logic(35) when (ep05wire(3)='0' and ep06wire(3)='1') else
                    ep06wire(3);
    logic_out(36) <= sequence_logic(36) when (ep05wire(4)='0' and ep06wire(4)='0') else
                    not sequence_logic(36) when (ep05wire(4)='0' and ep06wire(4)='1') else
                    ep06wire(4);
    logic_out(37) <= sequence_logic(37) when (ep05wire(5)='0' and ep06wire(5)='0') else
                    not sequence_logic(37) when (ep05wire(5)='0' and ep06wire(5)='1') else
                    ep06wire(5);
    logic_out(38) <= sequence_logic(38) when (ep05wire(6)='0' and ep06wire(6)='0') else
                    not sequence_logic(38) when (ep05wire(6)='0' and ep06wire(6)='1') else
                    ep06wire(6);
    logic_out(39) <= sequence_logic(39) when (ep05wire(7)='0' and ep06wire(7)='0') else
                    not sequence_logic(39) when (ep05wire(7)='0' and ep06wire(7)='1') else
                    ep06wire(7);
    logic_out(40) <= sequence_logic(40) when (ep05wire(8)='0' and ep06wire(8)='0') else
                    not sequence_logic(40) when (ep05wire(8)='0' and ep06wire(8)='1') else
                    ep06wire(8);
    logic_out(41) <= sequence_logic(41) when (ep05wire(9)='0' and ep06wire(9)='0') else
                    not sequence_logic(41) when (ep05wire(9)='0' and ep06wire(9)='1') else
                    ep06wire(9);
    logic_out(42) <= sequence_logic(42) when (ep05wire(10)='0' and ep06wire(10)='0') else
                    not sequence_logic(42) when (ep05wire(10)='0' and ep06wire(10)='1') else
                    ep06wire(10);
    logic_out(43) <= sequence_logic(43) when (ep05wire(11)='0' and ep06wire(11)='0') else
                    not sequence_logic(43) when (ep05wire(11)='0' and ep06wire(11)='1') else
                    ep06wire(11);
    logic_out(44) <= sequence_logic(44) when (ep05wire(12)='0' and ep06wire(12)='0') else
                    not sequence_logic(44) when (ep05wire(12)='0' and ep06wire(12)='1') else
                    ep06wire(12);
    logic_out(45) <= sequence_logic(45) when (ep05wire(13)='0' and ep06wire(13)='0') else
                    not sequence_logic(45) when (ep05wire(13)='0' and ep06wire(13)='1') else
                    ep06wire(13);
    logic_out(46) <= sequence_logic(46) when (ep05wire(14)='0' and ep06wire(14)='0') else
                    not sequence_logic(46) when (ep05wire(14)='0' and ep06wire(14)='1') else
                    ep06wire(14);
    logic_out(47) <= sequence_logic(47) when (ep05wire(15)='0' and ep06wire(15)='0') else
                    not sequence_logic(47) when (ep05wire(15)='0' and ep06wire(15)='1') else
                    ep06wire(15);
    
    logic_out(48) <= sequence_logic(48) when (ep07wire(0)='0' and ep08wire(0)='0') else
                    not sequence_logic(48) when (ep07wire(0)='0' and ep08wire(0)='1') else
                    ep08wire(0);
    logic_out(49) <= sequence_logic(49) when (ep07wire(1)='0' and ep08wire(1)='0') else
                    not sequence_logic(49) when (ep07wire(1)='0' and ep08wire(1)='1') else
                    ep08wire(1);
    logic_out(50) <= sequence_logic(50) when (ep07wire(2)='0' and ep08wire(2)='0') else
                    not sequence_logic(50) when (ep07wire(2)='0' and ep08wire(2)='1') else
                    ep08wire(2);
    logic_out(51) <= sequence_logic(51) when (ep07wire(3)='0' and ep08wire(3)='0') else
                    not sequence_logic(51) when (ep07wire(3)='0' and ep08wire(3)='1') else
                    ep08wire(3);
    logic_out(52) <= sequence_logic(52) when (ep07wire(4)='0' and ep08wire(4)='0') else
                    not sequence_logic(52) when (ep07wire(4)='0' and ep08wire(4)='1') else
                    ep08wire(4);
    logic_out(53) <= sequence_logic(53) when (ep07wire(5)='0' and ep08wire(5)='0') else
                    not sequence_logic(53) when (ep07wire(5)='0' and ep08wire(5)='1') else
                    ep08wire(5);
    logic_out(54) <= sequence_logic(54) when (ep07wire(6)='0' and ep08wire(6)='0') else
                    not sequence_logic(54) when (ep07wire(6)='0' and ep08wire(6)='1') else
                    ep08wire(6);
    logic_out(55) <= sequence_logic(55) when (ep07wire(7)='0' and ep08wire(7)='0') else
                    not sequence_logic(55) when (ep07wire(7)='0' and ep08wire(7)='1') else
                    ep08wire(7);
    logic_out(56) <= sequence_logic(56) when (ep07wire(8)='0' and ep08wire(8)='0') else
                    not sequence_logic(56) when (ep07wire(8)='0' and ep08wire(8)='1') else
                    ep08wire(8);
    logic_out(57) <= sequence_logic(57) when (ep07wire(9)='0' and ep08wire(9)='0') else
                    not sequence_logic(57) when (ep07wire(9)='0' and ep08wire(9)='1') else
                    ep08wire(9);
    logic_out(58) <= sequence_logic(58) when (ep07wire(10)='0' and ep08wire(10)='0') else
                    not sequence_logic(58) when (ep07wire(10)='0' and ep08wire(10)='1') else
                    ep08wire(10);
    logic_out(59) <= sequence_logic(59) when (ep07wire(11)='0' and ep08wire(11)='0') else
                    not sequence_logic(59) when (ep07wire(11)='0' and ep08wire(11)='1') else
                    ep08wire(11);
    logic_out(60) <= sequence_logic(60) when (ep07wire(12)='0' and ep08wire(12)='0') else
                    not sequence_logic(60) when (ep07wire(12)='0' and ep08wire(12)='1') else
                    ep08wire(12);
    logic_out(61) <= sequence_logic(61) when (ep07wire(13)='0' and ep08wire(13)='0') else
                    not sequence_logic(61) when (ep07wire(13)='0' and ep08wire(13)='1') else
                    ep08wire(13);
    logic_out(62) <= sequence_logic(62) when (ep07wire(14)='0' and ep08wire(14)='0') else
                    not sequence_logic(62) when (ep07wire(14)='0' and ep08wire(14)='1') else
                    ep08wire(14);
    logic_out(63) <= sequence_logic(63) when (ep07wire(15)='0' and ep08wire(15)='0') else
                    not sequence_logic(63) when (ep07wire(15)='0' and ep08wire(15)='1') else
                    ep08wire(15);

ram_block : ram
generic map(
    data_depth => 24000, --update ram_addr too!
    data_width => 16)
port map(
    clock => ram_clk,
    data_i => ram_data_i,
    address => ram_addr,
    we => ram_we,
    data_o => ram_data_o
);

-- Instantiate the okHost and connect endpoints
okHI : okHost       port map (hi_in=>hi_in, hi_out=>hi_out, hi_inout=>hi_inout, ti_clk=>ti_clk, ok1=>ok1, ok2=>ok2);
okWO : okWireOR     generic map (N=>2) port map (ok2=>ok2, ok2s=>ok2s);
ep00 : okWireIn     port map (ok1=>ok1,                                ep_addr=>x"00", ep_dataout=>ep00wire);
ep01 : okWireIn     port map (ok1=>ok1,                                ep_addr=>x"01", ep_dataout=>ep01wire);
ep02 : okWireIn     port map (ok1=>ok1,                                ep_addr=>x"02", ep_dataout=>ep02wire);
ep03 : okWireIn     port map (ok1=>ok1,                                ep_addr=>x"03", ep_dataout=>ep03wire);
ep04 : okWireIn     port map (ok1=>ok1,                                ep_addr=>x"04", ep_dataout=>ep04wire);
ep05 : okWireIn     port map (ok1=>ok1,                                ep_addr=>x"05", ep_dataout=>ep05wire);
ep06 : okWireIn     port map (ok1=>ok1,                                ep_addr=>x"06", ep_dataout=>ep06wire);
ep07 : okWireIn     port map (ok1=>ok1,                                ep_addr=>x"07", ep_dataout=>ep07wire);
ep08 : okWireIn     port map (ok1=>ok1,                                ep_addr=>x"08", ep_dataout=>ep08wire);
--ep20 : okWireOut    port map (ok1=>ok1, ok2=>ok2s(1*17-1 downto 0*17), ep_addr=>x"20", ep_datain=>ep20wire);
ep60 : okTriggerOut port map (ok1=>ok1, ok2=>ok2s(1*17-1 downto 0*17), ep_addr=>x"60", ep_clk=>clk, ep_trigger=>ep60trig);
ep80 : okPipeIn     port map (ok1=>ok1, ok2=>ok2s(2*17-1 downto 1*17), ep_addr=>x"80", ep_dataout=>ep80pipe, ep_write=>ep80write);

end arch;
