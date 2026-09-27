#ifndef LEPTON_CCI_H
#define LEPTON_CCI_H

#include <stdint.h>

void lepton_cci_init(void);
int lepton_cci_configure(void);
int lepton_cci_run_ffc(void);
int lepton_cci_reboot(void);
int lepton_cci_last_camera_error(void);

#endif
