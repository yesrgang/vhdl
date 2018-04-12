library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ram is
    generic (
        data_depth  : integer;
        data_width  : integer
	);
    port (
        clock         : in std_logic;
        we            : in std_logic;
        address       : in integer range 0 to data_depth - 1 := 0;
        data_i        : in std_logic_vector(data_width - 1 downto 0);
        data_o        : out std_logic_vector(3*data_width - 1 downto 0) := (others => '0')
    );
end ram;

architecture ram_arch of ram is
	type ram_type is array(0 to data_depth - 1) of std_logic_vector(data_width - 1 downto 0);
	signal ram_block : ram_type := (others => (others => '0'));
begin
	process (clock, ram_block, address, data_i, we)
	begin
		if rising_edge(clock) then
			if (we = '1') then
			    ram_block(address) <= data_i;
			end if;
            data_o <= ram_block(address+2)&ram_block(address+1)&ram_block(address+0); -- synch takes advantages of on board block ram
		end if;
        --data_o <= ram_block(address); -- or synch?, this works... uses LUTs
	end process;
end ram_arch;
