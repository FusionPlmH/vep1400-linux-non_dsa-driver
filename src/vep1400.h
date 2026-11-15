/* SPDX-License-Identifier: GPL-2.0 */
/* Shared entry points between the switch and board parts of vep1400.ko */

#ifndef _VEP1400_H
#define _VEP1400_H

int vep1400_board_init(void);
void vep1400_board_exit(void);

#endif /* _VEP1400_H */
