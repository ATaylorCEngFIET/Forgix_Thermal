import os, sys
sys.path.append(os.path.join(os.environ["EFXPT_HOME"], "bin"))
from api_service.design import DesignAPI

design = DesignAPI(is_verbose=False)
design.create("pll_probe", "T8F49", r"C:\hdl_projects\forgix_doom\lepton_thermal\fpga")
design.create_block("p", "PLL")
block = design.get_block("p", "PLL")
print(design.get_all_property("PLL", block))