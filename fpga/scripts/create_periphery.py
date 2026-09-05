#!/usr/bin/env python3
"""Generate the Efinity periphery database from the Forgix Lepton ISF."""

from __future__ import annotations

import os
from pathlib import Path
import sys


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    sys.path.append(str(Path(os.environ["EFXPT_HOME"]) / "bin"))

    from api_service.design import DesignAPI

    design_name = "forgix_lepton"
    peri_path = root / f"{design_name}.peri.xml"
    isf_path = root / "constraints" / f"{design_name}_io.isf"
    outflow = root / "outflow"

    if peri_path.exists():
        peri_path.unlink()

    design = DesignAPI(is_verbose=True)
    design.create(design_name, "T8F49", str(root))
    namespace = {"design": design}
    source = isf_path.read_text(encoding="utf-8")
    exec(compile(source, str(isf_path), "exec"), namespace)

    if not design.check_design():
        print("Periphery design check failed")
        return 1

    outflow.mkdir(exist_ok=True)
    design.generate(False, str(outflow))
    design.save()
    print(f"Generated {peri_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
