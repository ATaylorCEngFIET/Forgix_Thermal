library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package lepton_pkg is
  constant C_PACKET_BYTES       : natural := 164;
  constant C_PACKET_HEADER      : natural := 4;
  constant C_PACKET_PAYLOAD     : natural := 160;
  constant C_STREAM_PACKET_PAYLOAD : natural := 120;
  constant C_PACKETS_PER_SEGMENT: natural := 60;
  constant C_SEGMENT_BYTES      : natural := C_STREAM_PACKET_PAYLOAD * C_PACKETS_PER_SEGMENT;

  subtype t_byte is std_logic_vector(7 downto 0);
end package;
