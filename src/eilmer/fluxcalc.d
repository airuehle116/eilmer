/**
 * fluxcalc.d
 * Convective-Flux calculators, for use in the CFD codes.
 *
 * Author: Peter J. and Rowan G.
 * Version: 2014-07-23: initial cut, to explore options.
 */

module fluxcalc;

import std.math;
import std.stdio;
import std.conv;
import nm.complex;
import nm.number;

import geom;
import gas;
import flowstate;
import conservedquantities;
import fvinterface;
import globalconfig;

/** Compute the inviscid fluxes (in 1D) across the cell interfaces.
 *
 * This is the top-level function that calls the previously selected
 * flux calculator for open cell faces. i.e. those with cells either side.
 * Much of the detailed work is delegated.
 *
 * Lft : reference to the LEFT FlowState
 * Rght : reference to the RIGHT FlowState
 * f : reference to the interface where the fluxes are to be stored
 * myConfig : a block-local configuration object
 * omegaz : angular speed of the block
 *
 * Note that the FlowState objects, Lft and Rght, are tampered with.
 * Be sure that you use copies if you care about their content.
 */
@nogc
void compute_interface_flux(ref FlowState Lft, ref FlowState Rght, ref FVInterface f,
                            ref LocalConfig myConfig, double omegaz=0.0)
{
    if (f.left_cells.length == 0) {
        compute_flux_at_left_wall(Rght, f, myConfig, omegaz);
    } else if (f.right_cells.length == 0) {
        compute_flux_at_right_wall(Lft, f, myConfig, omegaz);
    } else {
        compute_interface_flux_interior(Lft, Rght, f, myConfig, omegaz);
    }
}

@nogc
void compute_interface_flux_interior(ref FlowState Lft, ref FlowState Rght,
                                     ref FVInterface IFace,
                                     ref LocalConfig myConfig, double omegaz=0.0)
{
    // Transform to interface frame of reference.
    // Firstly, subtract interface velocity, in the case where the grid is moving
    // we want the velocity of the flow relative to the interface.
    Lft.vel.x -= IFace.gvel.x; Lft.vel.y -= IFace.gvel.y; Lft.vel.z -= IFace.gvel.z;
    Rght.vel.x -= IFace.gvel.x; Rght.vel.y -= IFace.gvel.y; Rght.vel.z -= IFace.gvel.z;

    IFace.gvel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    Lft.vel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    Rght.vel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    version(MHD) {
        // Also transform the magnetic field
        if (myConfig.MHD) {
            Lft.B.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
            Rght.B.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
        }
    }
    // Compute the fluxes in the local frame of the interface.
    final switch (myConfig.flux_calculator) {
    case FluxCalculator.efm:
        efmflx(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.ausmdv:
        ausmdv(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.hllc:
        hllc(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.ldfss0:
        ldfss0(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.ldfss2:
        ldfss2(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.hanel:
        hanel(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.adaptive_efm_ausmdv:
        adaptive_efm_ausmdv(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.adaptive_hanel_ausmdv:
        adaptive_hanel_ausmdv(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.adaptive_hanel_ausm_plus_up:
        adaptive_hanel_ausm_plus_up(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.adaptive_ldfss0_ldfss2:
        adaptive_ldfss0_ldfss2(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.adaptive_hlle_hllc:
        adaptive_hlle_hllc(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.adaptive_hlle_roe:
        adaptive_hlle_roe(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.ausm_plus_up:
        ausm_plus_up(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.hlle:
        hlle(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.hlle2:
        hlle2(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.roe:
        roe(Lft, Rght, IFace, myConfig);
        break;
    case FluxCalculator.asf:
        ASF_242(IFace, myConfig);
        break;
    case FluxCalculator.adaptive_ausmdv_asf:
        adaptive_ausmdv_asf(Lft, Rght, IFace, myConfig);
        break;
    } // end switch
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    version(MHD) {
        // Adjustment of the magnetic field flux and associated parameter psi as per Dedner et al.
        if (myConfig.MHD) {
            F.vec[cqi.divB] = 0.5 * (Rght.B.x - Lft.B.x);
            if (myConfig.divergence_cleaning) {
                F.vec[cqi.xB] += Lft.psi + 0.5 * (Rght.psi - Lft.psi) - (myConfig.c_h / 2.0) * (Rght.B.x - Lft.B.x);
                F.vec[cqi.yB] += Lft.psi + 0.5 * (Rght.psi - Lft.psi) - (myConfig.c_h / 2.0) * (Rght.B.y - Lft.B.y);
                F.vec[cqi.xB] += Lft.psi + 0.5 * (Rght.psi - Lft.psi) - (myConfig.c_h / 2.0) * (Rght.B.z - Lft.B.z);
                F.vec[cqi.psi] += (Lft.B.x + 0.5 * (Rght.B.x - Lft.B.x) -
                                   (1.0 / (2.0 * myConfig.c_h)) * (Rght.psi - Lft.psi)) * myConfig.c_h^^2;
            }
        }
    }
    if (omegaz != 0.0) {
        // Rotating frame.
        number x = IFace.pos.x;
        number y = IFace.pos.y;
        number rsq = x*x + y*y;
        // The conserved quantity is rotating-frame total energy,
        // so we need to take -(u**2)/2 off the total energy.
        // Note that rotating frame velocity u = omegaz * r.
        F.vec[cqi.totEnergy] -= F.vec[cqi.mass] * 0.5*omegaz*omegaz*rsq;
    }
    // Transform fluxes back from interface frame of reference to local frame of reference.
    // Flux of Total Energy
    number v_sqr = IFace.gvel.x*IFace.gvel.x + IFace.gvel.y*IFace.gvel.y + IFace.gvel.z*IFace.gvel.z;
    F.vec[cqi.totEnergy] += 0.5 * F.vec[cqi.mass] * v_sqr +
        (F.vec[cqi.xMom]*IFace.gvel.x + F.vec[cqi.yMom]*IFace.gvel.y +
         ((cqi.threeD) ? F.vec[cqi.zMom]*IFace.gvel.z: to!number(0.0)));
    // Flux of momentum: Add component for interface velocity then
    // rotate back to the global frame of reference.
    F.vec[cqi.xMom] += IFace.gvel.x * F.vec[cqi.mass];
    F.vec[cqi.yMom] += IFace.gvel.y * F.vec[cqi.mass];
    if (cqi.threeD) {
        F.vec[cqi.zMom] += IFace.gvel.z * F.vec[cqi.mass];
        transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], F.vec[cqi.zMom], IFace.n, IFace.t1, IFace.t2);
    } else {
        number zDummy = to!number(0.0);
        transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], zDummy, IFace.n, IFace.t1, IFace.t2);
    }
    // Also, transform the interface (grid) velocity and magnetic field.
    IFace.gvel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
    version(MHD) {
        if (myConfig.MHD) {
            transform_to_global_frame(F.vec[cqi.xB], F.vec[cqi.yB], F.vec[cqi.zB], IFace.n, IFace.t1, IFace.t2);
        }
    }
    return;
} // end compute_interface_flux_interior()

@nogc
void compute_flux_at_left_wall(ref FlowState Rght, ref FVInterface IFace,
                               ref LocalConfig myConfig, double omegaz=0.0)
{
    // Transform to interface frame of reference.
    IFace.gvel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    Rght.vel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    version(MHD) {
        // Also transform the magnetic field
        if (myConfig.MHD) { Rght.B.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2); }
    }
    // Compute the fluxes in the local frame of the interface,
    // presuming that there is a right-running wave which processes the gas
    // from the initial right-flow-state to that at the wall.
    // See PJ workbook notes 2018-06-09.
    // Source of this calculation is the 1998 report on L1d, Report 13/98.
    number vstar = IFace.gvel.x;
    number aR = Rght.gas.a;
    number vR = Rght.vel.x;
    number g = myConfig.gmodel.gamma(Rght.gas);
    // Riemann invariant across left-running wave.
    number Jminus = vR - 2.0*aR/(g-1.0);
    // Set up to compute pressure at wall, pstar.
    number rhoR = Rght.gas.rho;
    number pR = Rght.gas.p;
    number tmp = (vstar - Jminus)*(g-1.0)/(2.0*sqrt(g))*sqrt(rhoR/pow(pR,1.0/g));
    number ptiny = myConfig.flowstate_limits.min_pressure;
    number pstar = (tmp > 0.0) ? pow(tmp, 2.0*g/(g-1.0)) : ptiny;
    if (pstar > 1.1*pR) {
        // Shock wave processing. See PJ workbook notes 2019-05-22, pages 71-74.
        number f(number ps)
        {
            number xi = ps/pR;
            number M1sq = 1.0 + (g+1.0)/2.0/g*(xi-1.0);
            number v1 = sqrt(M1sq)*aR;
            number v2 = v1*((g-1.0)*M1sq+2.0)/((g+1.0)*M1sq);
            return vstar - v1 + v2 - vR;
        }
        int count = 0;
        number incr_pstar;
        do {
            number f0 = f(pstar);
            number dp = 0.001 * pstar;
            number f1 = f(pstar+dp);
            incr_pstar = -f0*dp/(f1-f0);
            pstar += incr_pstar;
            count += 1;
        } while (fabs(incr_pstar)/pstar > 0.01 && count < 10);
    }
    // Limit the post-wave pressure to handle extreme boundary situations
    // where there is a large velocity difference between the cell centre and the wall.
    pstar = fmin(pstar, pR*10.0);
    //
    // Fill in the fluxes.
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    F.vec[cqi.mass] = 0.0;
    F.vec[cqi.xMom] = pstar;
    F.vec[cqi.yMom] = 0.0;
    if (cqi.threeD) { F.vec[cqi.zMom] = 0.0; }
    F.vec[cqi.totEnergy] = pstar * vstar;
    version(turbulence) {
        foreach (i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] = 0.0; }
    }
    version(multi_species_gas) {
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] = 0.0; }
        }
    }
    version(multi_T_gas) {
        foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] = 0.0; }
    }
    version(MHD) {
        if (cqi.MHD) {
            // [TODO] magnetic field.
            F.vec[cqi.xB] = 0.0;
            F.vec[cqi.yB] = 0.0;
            F.vec[cqi.zB] = 0.0;
            F.vec[cqi.psi] = 0.0;
            F.vec[cqi.divB] = 0.0;
        }
    }
    // Rotate back to the global frame of reference.
    if (cqi.threeD) {
        F.vec[cqi.zMom] += IFace.gvel.z * F.vec[cqi.mass];
        transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], F.vec[cqi.zMom], IFace.n, IFace.t1, IFace.t2);
    } else {
        number zDummy = 0.0;
        transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], zDummy, IFace.n, IFace.t1, IFace.t2);
    }
    // Also, transform the interface (grid) velocity
    IFace.gvel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
    version(MHD) {
        if (myConfig.MHD) {
            transform_to_global_frame(F.vec[cqi.xB], F.vec[cqi.yB], F.vec[cqi.zB], IFace.n, IFace.t1, IFace.t2);
        }
    }
    return;
} // end compute_flux_at_left_wall()

@nogc
void compute_flux_at_right_wall(ref FlowState Lft, ref FVInterface IFace,
                                ref LocalConfig myConfig, double omegaz=0.0)
{
    // Transform to interface frame of reference.
    IFace.gvel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    Lft.vel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    version(MHD) {
        // Also transform the magnetic field
        if (myConfig.MHD) { Lft.B.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2); }
    }
    // Compute the fluxes in the local frame of the interface,
    // presuming that there is a right-running wave which processes the gas
    // from the initial right-flow-state to that at the wall.
    // See PJ workbook notes 2018-06-09.
    // Source of this calculation is the 1998 report on L1d, Report 13/98.
    number vstar = IFace.gvel.x;
    number aL = Lft.gas.a;
    number vL = Lft.vel.x;
    number g = myConfig.gmodel.gamma(Lft.gas);
    // Riemann invariant across left-running wave.
    number Jplus = vL + 2.0*aL/(g-1.0);
    // Set up to compute pressure at wall, pstar.
    number rhoL = Lft.gas.rho;
    number pL = Lft.gas.p;
    number tmp = (Jplus - vstar)*(g-1.0)/(2.0*sqrt(g))*sqrt(rhoL/pow(pL,1.0/g));
    number ptiny = myConfig.flowstate_limits.min_pressure;
    number pstar = (tmp > 0.0) ? pow(tmp, 2.0*g/(g-1.0)) : ptiny;
    if (pstar > 1.1*pL) {
        // Shock wave processing. See PJ workbook notes 2019-05-22, pages 71-74.
        number f(number ps)
        {
            number xi = ps/pL;
            number M1sq = 1.0 + (g+1.0)/2.0/g*(xi-1.0);
            number v1 = sqrt(M1sq)*aL;
            number v2 = v1*((g-1.0)*M1sq+2.0)/((g+1.0)*M1sq);
            return vstar + v1 - v2 - vL;
        }
        int count = 0;
        number incr_pstar;
        do {
            number f0 = f(pstar);
            number dp = 0.001 * pstar;
            number f1 = f(pstar+dp);
            incr_pstar = -f0*dp/(f1-f0);
            pstar += incr_pstar;
            count += 1;
        } while (fabs(incr_pstar)/pstar > 0.01 && count < 10);
    }
    // Limit the post-wave pressure to handle extreme boundary situations
    // where there is a large velocity difference between the cell centre and the wall.
    pstar = fmin(pstar, pL*10.0);
    //
    // Fill in the fluxes.
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    F.vec[cqi.mass] = 0.0;
    F.vec[cqi.xMom] = pstar;
    F.vec[cqi.yMom] = 0.0;
    if (cqi.threeD) { F.vec[cqi.zMom] = 0.0; }
    F.vec[cqi.totEnergy] = pstar * vstar;
    version(turbulence) {
        foreach (i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] = 0.0; }
    }
    version(multi_species_gas) {
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] = 0.0; }
        }
    }
    version(multi_T_gas) {
        foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] = 0.0; }
    }
    version(MHD) {
        if (cqi.MHD) {
            // [TODO] magnetic field.
            F.vec[cqi.xB] = 0.0;
            F.vec[cqi.yB] = 0.0;
            F.vec[cqi.zB] = 0.0;
            F.vec[cqi.psi] = 0.0;
            F.vec[cqi.divB] = 0.0;
        }
    }
    // Rotate back to the global frame of reference.
    if (cqi.threeD) {
        F.vec[cqi.zMom] += IFace.gvel.z * F.vec[cqi.mass];
        transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], F.vec[cqi.zMom], IFace.n, IFace.t1, IFace.t2);
    } else {
        number zDummy = to!number(0.0);
        transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], zDummy, IFace.n, IFace.t1, IFace.t2);
    }
    // Also, transform the interface (grid) velocity
    IFace.gvel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
    version(MHD) {
        // and transform the magnetic field
        if (myConfig.MHD) {
            transform_to_global_frame(F.vec[cqi.xB], F.vec[cqi.yB], F.vec[cqi.zB], IFace.n, IFace.t1, IFace.t2);
        }
    }
    return;
} // end  compute_flux_at_right_wall()

@nogc
void set_flux_vector_in_local_frame(ref ConservedQuantities F, ref FlowState fs,
                                    ref LocalConfig myConfig)
{
    number rho = fs.gas.rho;
    number vn = fs.vel.x;
    number vt1 = fs.vel.y;
    number vt2 = fs.vel.z;
    number p = fs.gas.p;
    number u = myConfig.gmodel.internal_energy(fs.gas);
    number ke = 0.5 * (vn*vn + vt1*vt1 + vt2*vt2); // Kinetic energy per unit volume.
    //
    // Fluxes (quantity / unit time / unit area)
    auto cqi = myConfig.cqi;
    F.vec[cqi.mass] = rho * vn; // The mass flux is relative to the moving interface.
    F.vec[cqi.xMom] = F.vec[cqi.mass]*vn + p;
    F.vec[cqi.yMom] = F.vec[cqi.mass]*vt1;
    if (cqi.threeD) { F.vec[cqi.zMom] = F.vec[cqi.mass]*vt2; }
    F.vec[cqi.totEnergy] = F.vec[cqi.mass]*(u+ke) + p*vn;
    version(turbulence) {
        F.vec[cqi.totEnergy] += myConfig.turb_model.turbulent_kinetic_energy(fs);
        foreach(i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] = F.vec[cqi.mass] * fs.turb[i]; }
    }
    version(multi_species_gas) {
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] = F.vec[cqi.mass]*fs.gas.massf[i]; }
        }
    }
    version(multi_T_gas) {
        foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] = F.vec[cqi.mass]*fs.gas.u_modes[i]; }
    }
} // end set_flux_vector_in_local_frame()

@nogc
void set_flux_vector_in_global_frame(ref FVInterface IFace, ref FlowState fs,
                                     ref LocalConfig myConfig, double omegaz=0.0)
{
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    // Record velocity to restore fs at end.
    number vx = fs.vel.x; number vy = fs.vel.y; number vz = fs.vel.z;
    // Transform to interface frame of reference.
    // Beware: fs.vel is changed here and restored below.
    fs.vel.x -= IFace.gvel.x; fs.vel.y -= IFace.gvel.y; fs.vel.z -= IFace.gvel.z;
    IFace.gvel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    fs.vel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    version(MHD) {
        // also transform the magnetic field
        if (myConfig.MHD) { fs.B.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2); }
    }
    set_flux_vector_in_local_frame(IFace.F, fs, myConfig);
    if (omegaz != 0.0) {
        // Rotating frame.
        number x = IFace.pos.x;
        number y = IFace.pos.y;
        number rsq = x*x + y*y;
        // The conserved quantity is rothalpy,
        // so we need to take -(u**2)/2 off the total energy flux.
        // Note that rotating frame velocity u = omegaz * r.
        F.vec[cqi.totEnergy] -= F.vec[cqi.mass] * 0.5*omegaz*omegaz*rsq;
    }
    //
    // Transform fluxes back from interface frame of reference to local frame of reference.
    // Then, rotate momentum fluxes back to the global frame of reference.
    number v_sqr = (IFace.gvel.x)^^2 + (IFace.gvel.y)^^2 + (IFace.gvel.z)^^2;
    F.vec[cqi.totEnergy] += 0.5*F.vec[cqi.mass]*v_sqr + F.vec[cqi.xMom]*IFace.gvel.x +
        F.vec[cqi.yMom]*IFace.gvel.y + ((cqi.threeD) ? F.vec[cqi.zMom]*IFace.gvel.z : to!number(0.0));
    F.vec[cqi.xMom] += F.vec[cqi.mass] * IFace.gvel.x;
    F.vec[cqi.yMom] += F.vec[cqi.mass] * IFace.gvel.y;
    if (cqi.threeD) {
        F.vec[cqi.zMom] += F.vec[cqi.mass] * IFace.gvel.z;
        transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], F.vec[cqi.zMom], IFace.n, IFace.t1, IFace.t2);
    } else {
        number zDummy = 0.0;
        transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], zDummy, IFace.n, IFace.t1, IFace.t2);
    }
    // also transform the interface (grid) velocity
    IFace.gvel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
    version(MHD) {
        if (myConfig.MHD) {
            transform_to_global_frame(F.vec[cqi.xB], F.vec[cqi.yB], F.vec[cqi.zB], IFace.n, IFace.t1, IFace.t2);
        }
    }
    fs.vel.set(vx, vy, vz); // restore fs.vel
} // end set_flux_vector_in_global_frame()

@nogc
void ausmdv(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0)
// Wada and Liou's flux calculator.
//
// Implemented from details in their AIAA paper
// with hints from Ian Johnston.
// Y. Wada and M. -S. Liou (1994)
// A flux splitting scheme with high-resolution and robustness for discontinuities.
// AIAA-94-0083.
{
    auto gmodel = myConfig.gmodel;
    // Unpack the flow-state vectors for either side of the interface.
    // Store in work vectors, those quantities that will be neede later.
    number rL = Lft.gas.rho;
    number pL = Lft.gas.p;
    number pLrL = pL / rL;
    number uL = Lft.vel.x;
    number vL = Lft.vel.y;
    number wL = Lft.vel.z;
    number eL = gmodel.internal_energy(Lft.gas);
    number aL = Lft.gas.a;
    number keL = 0.5*(uL*uL + vL*vL + wL*wL);
    number HL = eL + pLrL + keL;
    version(turbulence) { HL += myConfig.turb_model.turbulent_kinetic_energy(Lft); }
    //
    number rR = Rght.gas.rho;
    number pR = Rght.gas.p;
    number pRrR = pR / rR;
    number uR = Rght.vel.x;
    number vR = Rght.vel.y;
    number wR = Rght.vel.z;
    number eR = gmodel.internal_energy(Rght.gas);
    number aR = Rght.gas.a;
    number keR = 0.5*(uR*uR + vR*vR + wR*wR);
    number HR = eR + pRrR + keR;
    version(turbulence) { HR += myConfig.turb_model.turbulent_kinetic_energy(Rght); }
    //
    // This is the main part of the flux calculator.
    // Weighting parameters (eqn 32) for velocity splitting.
    number alphaL = 2.0 * pLrL / (pLrL + pRrR);
    number alphaR = 2.0 * pRrR / (pLrL + pRrR);
    // Common sound speed (eqn 33) and Mach numbers.
    number am = fmax(aL, aR);
    number ML = uL / am;
    number MR = uR / am;
    // Left state:
    // pressure splitting (eqn 34)
    // and velocity splitting (eqn 30)
    number pLplus, uLplus;
    number duL = 0.5 * (uL + fabs(uL));
    if (fabs(ML) <= 1.0) {
        pLplus = pL * (ML + 1.0) * (ML + 1.0) * (2.0 - ML) * 0.25;
        uLplus = alphaL * ((uL + am) * (uL + am) / (4.0 * am) - duL) + duL;
    } else {
        pLplus = pL * duL / uL;
        uLplus = duL;
    }
    // Right state:
    // pressure splitting (eqn 34)
    // and velocity splitting (eqn 31)
    number pRminus, uRminus;
    number duR = 0.5 * (uR - fabs(uR));
    if (fabs(MR) <= 1.0) {
        pRminus = pR * (MR - 1.0) * (MR - 1.0) * (2.0 + MR) * 0.25;
        uRminus = alphaR * (-(uR - am) * (uR - am) / (4.0 * am) - duR) + duR;
    } else {
        pRminus = pR * duR / uR;
        uRminus = duR;
    }
    // Mass Flux (eqn 29)
    // The mass flux is relative to the moving interface.
    number ru_half = uLplus * rL + uRminus * rR;
    // Pressure flux (eqn 34)
    number p_half = pLplus + pRminus;
    // Momentum flux: normal direction
    // Compute blending parameter s (eqn 37),
    // the momentum flux for AUSMV (eqn 21) and AUSMD (eqn 21)
    // and blend (eqn 36).
    number dp = pL - pR;
    const double K_SWITCH = 10.0;
    dp = K_SWITCH * fabs(dp) / fmin(pL, pR);
    number s = 0.5 * fmin(1.0, dp);
    number ru2_AUSMV = uLplus * rL * uL + uRminus * rR * uR;
    number ru2_AUSMD = 0.5 * (ru_half * (uL + uR) - fabs(ru_half) * (uR - uL));
    number ru2_half = (0.5 + s) * ru2_AUSMV + (0.5 - s) * ru2_AUSMD;
    //
    // Assemble components of the flux vector.
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    F.vec[cqi.mass] += factor*ru_half;
    if (ru_half >= 0.0) {
        // Wind is blowing from the left.
        F.vec[cqi.xMom] += (ru2_half+p_half) * factor;
        F.vec[cqi.yMom] += (ru_half*vL) * factor;
        if (cqi.threeD) { F.vec[cqi.zMom] += (ru_half*wL) * factor; }
        F.vec[cqi.totEnergy] += factor*ru_half*HL;
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] += factor*ru_half*Lft.turb[i]; }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] += factor*ru_half*Lft.gas.massf[i]; }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] += factor*ru_half*Lft.gas.u_modes[i]; }
        }
        // NOTE: - the following relies on the free-electron mode being the last mode
        //       - for single temp models F_renergies isn't used
        //       - for multitemp modes with no free-electrons p_e is zero
        // Add electron pressure work term onto final energy mode
        // FIX-ME F.energies[nmodes-1] += ru_half * Lft.gas.p_e / Lft.gas.rho;
    } else {
        // Wind is blowing from the right.
        F.vec[cqi.xMom] += (ru2_half+p_half) * factor;
        F.vec[cqi.yMom] += (ru_half*vR) * factor;
        if (cqi.threeD) { F.vec[cqi.zMom] += (ru_half*wR) * factor; }
        F.vec[cqi.totEnergy] += factor*ru_half*HR;
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] += factor*ru_half*Rght.turb[i]; }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] += factor*ru_half*Rght.gas.massf[i]; }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] += factor*ru_half*Rght.gas.u_modes[i]; }
        }
    }
    //
    // Apply entropy fix (section 3.5 in Wada and Liou's paper)
    if (myConfig.apply_entropy_fix) {
        const double C_EFIX = 0.125;
        bool caseA = ((uL - aL) < 0.0) && ((uR - aR) > 0.0);
        bool caseB = ((uL + aL) < 0.0) && ((uR + aR) > 0.0);
        //
        number d_ua = 0.0;
        if (caseA && !caseB) { d_ua = C_EFIX * ((uR - aR) - (uL - aL)); }
        if (caseB && !caseA) { d_ua = C_EFIX * ((uR + aR) - (uL + aL)); }
        //
        if (d_ua != 0.0) {
            F.vec[cqi.mass] -= factor*d_ua*(rR - rL);
            F.vec[cqi.xMom] -= factor*d_ua*(rR*uR - rL*uL);
            F.vec[cqi.yMom] -= factor*d_ua*(rR*vR - rL*vL);
            if (cqi.threeD) { F.vec[cqi.zMom] -= factor*d_ua*(rR*wR - rL*wL); }
            F.vec[cqi.totEnergy] -= factor*d_ua*(rR*HR - rL*HL);
            version(turbulence) {
                foreach(i; 0 .. myConfig.turb_model.nturb) {
                    F.vec[cqi.rhoturb+i] -= factor*d_ua*(rR*Rght.turb[i] - rL*Lft.turb[i]);
                }
            }
            version(multi_species_gas) {
                if (cqi.n_species > 1) {
                    foreach (i; 0 .. cqi.n_species) {
                        F.vec[cqi.species+i] -= factor*d_ua*(rR*Rght.gas.massf[i] - rL*Lft.gas.massf[i]);
                    }
                }
            }
            version(multi_T_gas) {
                foreach (i; 0 .. cqi.n_modes) {
                    F.vec[cqi.modes+i] -= factor*d_ua*(rR*Rght.gas.u_modes[i] - rL*Lft.gas.u_modes[i]);
                }
            }
        } // end of entropy fix (d_ua != 0)
    }
} // end ausmdv()

@nogc
void hllc(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0)
// HLLC flux calculator.
//
// Implemented from details in
//     Toro (2009)
//     Riemann solvers and numerical methods for fluid dynamics,
//     textbook on pg. 331-332.
// and
//     E. F. Toro, M. Spruce, and W. Speares
//     Restoration of the contact surface in the HLL-Riemann solver
//     Shock Waves (1994)
//
{
    auto gmodel = myConfig.gmodel;
    // Unpack the flow-state vectors for either side of the interface.
    // Store in work vectors, those quantities that will be neede later.
    number gL = gmodel.gamma(Lft.gas);
    number rL = Lft.gas.rho;
    number pL = Lft.gas.p;
    number uL = Lft.vel.x;
    number vL = Lft.vel.y;
    number wL = Lft.vel.z;
    number eL = gmodel.internal_energy(Lft.gas);
    number aL = Lft.gas.a;
    number keL = 0.5*(uL*uL + vL*vL + wL*wL);
    number EL = rL*eL + rL*keL;
    number HL = eL + pL/rL + keL;
    version(turbulence) {
        EL += rL*myConfig.turb_model.turbulent_kinetic_energy(Lft);
        HL += rL*myConfig.turb_model.turbulent_kinetic_energy(Lft);
    }
    //
    number gR = gmodel.gamma(Rght.gas);
    number rR = Rght.gas.rho;
    number pR = Rght.gas.p;
    number pRrR = pR / rR;
    number uR = Rght.vel.x;
    number vR = Rght.vel.y;
    number wR = Rght.vel.z;
    number eR = gmodel.internal_energy(Rght.gas);
    number aR = Rght.gas.a;
    number keR = 0.5*(uR*uR + vR*vR + wR*wR);
    number ER = rR*eR + rR*keR;
    number HR = eR + pR/rR + keR;
    version(turbulence) {
        ER += rR*myConfig.turb_model.turbulent_kinetic_energy(Rght);
        HR += rR*myConfig.turb_model.turbulent_kinetic_energy(Rght);
    }
    //

    // compute Roe-average state
    number uhat = (sqrt(rL)*uL+sqrt(rR)*uR) / (sqrt(rL) + sqrt(rR));
    number vhat = (sqrt(rL)*vL+sqrt(rR)*vR) / (sqrt(rL) + sqrt(rR));
    number what = (sqrt(rL)*wL+sqrt(rR)*wR) / (sqrt(rL) + sqrt(rR));
    number Hhat = (sqrt(rL)*HL+sqrt(rR)*HR) / (sqrt(rL) + sqrt(rR));
    number kehat = 0.5*(uhat*uhat+vhat*vhat+what*what);
    number ghat = (sqrt(rL)*gL+sqrt(rR)*gR) / (sqrt(rL) + sqrt(rR));
    number ahat2 = (ghat-1.0)*(Hhat-kehat);
    number ahat = sqrt(ahat2);

    // compute wave estimates
    number SL = fmin(uhat-ahat, uL-aL);
    number SR = fmax(uhat+ahat, uR+aR);
    number S_star = (pR - pL + rL*uL*(SL - uL) - rR*uR*(SR - uR))/(rL*(SL - uL) - rR*(SR - uR));
    
    // compute HLLC flux
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    // a helper function that evaluates the HLLC fluxes used to reduce repeated code
    void hllc_flux_function(bool star_region, number coeff, number r, number p, number u, number v, number w, number E, in FlowState state, number S) {
        // mass
        number F_mass = r*u;
        number U_mass = r;
        number U_star_mass = coeff;
        if (star_region) { F.vec[cqi.mass] += factor*(F_mass + S*(U_star_mass - U_mass)); }
        else { F.vec[cqi.mass] += factor*(F_mass); }
        // momentum
        // x
        number F_momx = r*u*u + p;
        number U_momx = r*u;
        number U_star_momx = coeff*S_star;
        // y
        number F_momy = r*u*v;
        number U_momy = r*v;
        number U_star_momy = coeff*v;
        // z
        number F_momz = r*u*w;
        number U_momz = r*w;
        number U_star_momz = coeff*w;
        if (star_region) {
            F.vec[cqi.xMom] += factor * (F_momx + S*(U_star_momx - U_momx));
            F.vec[cqi.yMom] += factor * (F_momy + S*(U_star_momy - U_momy));
            if (cqi.threeD) { F.vec[cqi.zMom] += factor * (F_momz + S*(U_star_momz - U_momz)); }
        } else {
            F.vec[cqi.xMom] += factor * F_momx;
            F.vec[cqi.yMom] += factor * F_momy;
            if (cqi.threeD) { F.vec[cqi.zMom] += factor * F_momz; }
        }
        // total energy
        number F_totenergy = u*(E + p);
        number U_totenergy = E;
        number U_star_totenergy = coeff*(E/r + (S_star - u)*(S_star + p/(r*(S - u))));
        if (star_region) { F.vec[cqi.totEnergy] += factor*(F_totenergy + S*(U_star_totenergy - U_totenergy)); }
        else { F.vec[cqi.totEnergy] += factor*(F_totenergy); }
        // turbulence
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) {
                number F_rhoturb = r*u*state.turb[i];
                number U_rhoturb = r*state.turb[i];
                number U_star_rhoturb = coeff*state.turb[i];
                if (star_region) { F.vec[cqi.rhoturb+i] += factor*(F_rhoturb + S*(U_star_rhoturb - U_rhoturb)); }
                else { F.vec[cqi.rhoturb+i] += factor*(F_rhoturb); }
            }
        }
        // multi-species
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) {
                    number F_massf = r*u*state.gas.massf[i];
                    number U_massf = r*state.gas.massf[i];
                    number U_star_massf = coeff*state.gas.massf[i];
                    if (star_region) { F.vec[cqi.species+i] += factor*(F_massf + S*(U_star_massf - U_massf)); }
                    else { F.vec[cqi.species+i] += factor*(F_massf); }
                }
            }
        }
        // multi-T gas
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) {
                number F_energies = r*u*state.gas.u_modes[i];
                number U_energies = r*state.gas.u_modes[i];
                number U_star_energies = coeff*state.gas.u_modes[i];
                if (star_region) { F.vec[cqi.modes+i] += factor*(F_energies + S*(U_star_energies - U_energies)); }
                else { F.vec[cqi.modes+i] += factor*(F_energies); }
            }
        }
    }

    // evaluate HLLC fluxes
    if (S_star > 0.0) {
        if (SL > 0.0) {
            // compute Left Flux
            number coeffL = 0.0;
            hllc_flux_function(false, coeffL, rL, pL, uL, vL, wL, EL, Lft, SL);
        } else {
            // compute Flux Left Star from Left Star State
            number coeffL = rL*(SL-uL)/(SL-S_star);
            hllc_flux_function(true, coeffL, rL, pL, uL, vL, wL, EL, Lft, SL);
        }
    } else {
        if (SR < 0.0) {
            // compute Right Flux
            number coeffR = 0.0;
            hllc_flux_function(false, coeffR, rR, pR, uR, vR, wR, ER, Rght, SR);
        } else {
            // compute Flux Right Star from Right Star State
            number coeffR = rR*(SR-uR)/(SR-S_star);
            hllc_flux_function(true, coeffR, rR, pR, uR, vR, wR, ER, Rght, SR);
        }
    }
} // end hllc()

@nogc
void ldfss0(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0)
// Jack Edwards' LDFSS (variant 0) flux calculator.
//
// Implemented from details in
//     Jack R. Edwards (1997)
//     A low-diffusion flux-splitting scheme for Navier-Stokes calculations.
//     Computers & Fluids paper.
//
{
    auto gmodel = myConfig.gmodel;
    // Unpack the flow-state vectors for either side of the interface.
    // Store in work vectors, those quantities that will be neede later.
    number rL = Lft.gas.rho;
    number pL = Lft.gas.p;
    number pLrL = pL / rL;
    number uL = Lft.vel.x;
    number vL = Lft.vel.y;
    number wL = Lft.vel.z;
    number eL = gmodel.internal_energy(Lft.gas);
    number aL = Lft.gas.a;
    number keL = 0.5*(uL*uL + vL*vL + wL*wL);
    number HL = eL + pLrL + keL;
    version(turbulence) { HL += myConfig.turb_model.turbulent_kinetic_energy(Lft); }
    //
    number rR = Rght.gas.rho;
    number pR = Rght.gas.p;
    number pRrR = pR / rR;
    number uR = Rght.vel.x;
    number vR = Rght.vel.y;
    number wR = Rght.vel.z;
    number eR = gmodel.internal_energy(Rght.gas);
    number aR = Rght.gas.a;
    number keR = 0.5*(uR*uR + vR*vR + wR*wR);
    number HR = eR + pRrR + keR;
    version(turbulence) { HR += myConfig.turb_model.turbulent_kinetic_energy(Rght); }
    //
    // Split Mach number (eqn 15)
    number ML = uL / aL;
    number MR = uR / aR;
    number MpL = 0.25*(ML + 1.0)^^2;
    number MmR = -0.25*(MR - 1.0)^^2;
    // Parameters to provide correct sonic-point transition behaviour
    // equation 16
    number alphaL = 0.5*(1.0 + sgn(ML.re));
    number alphaR = 0.5*(1.0 - sgn(MR.re));
    // equation 17
    number betaL = -fmax(0.0, 1.0-floor(fabs(ML.re)));
    number betaR = -fmax(0.0, 1.0-floor(fabs(MR.re)));
    // subsonic pressure splitting (eqn 12)
    number PL = 0.25*(ML+1.0)^^2*(2.0-ML);
    number PR = 0.25*(MR-1.0)^^2*(2.0+MR);
    // D parameter (eqn 11)
    number DL = alphaL*(1.0+betaL) - betaL*PL;
    number DR = alphaR*(1.0+betaR) - betaR*PR;
    // M_1/2 parameters for LDFSS (0) (eqn 20)
    number Mhalf = 0.25*betaL*betaR*(sqrt(0.5*(ML^^2+MR^^2))-1.0)^^2;
    // C parameter for LDFSS (0) (en 13 & en 14 & eqn 18 & eqn 19)
    number CL = alphaL*(1.0+betaL)*ML - betaL*MpL - Mhalf;
    number CR = alphaR*(1.0+betaR)*MR - betaR*MmR + Mhalf;
    //
    // Assemble components of the flux vector.
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    number ru_half = aL*rL*CL + aR*rR*CR;
    number ru2_half = aL*rL*CL*uL + aR*rR*CR*uR;
    number p_half = DL*pL + DR*pR;
    F.vec[cqi.mass] += factor*ru_half;
    F.vec[cqi.xMom] += factor*(ru2_half+p_half);
    F.vec[cqi.yMom] += factor*(aL*rL*CL*vL + aR*rR*CR*vR);
    if (cqi.threeD) { F.vec[cqi.zMom] += factor*(aL*rL*CL*wL + aR*rR*CR*wR); }
    F.vec[cqi.totEnergy] += factor*(aL*rL*CL*HL + aR*rR*CR*HR);
    version(turbulence) {
        foreach(i; 0 .. myConfig.turb_model.nturb) {
            F.vec[cqi.rhoturb+i] += factor*(aL*rL*CL*Lft.turb[i] + aR*rR*CR*Rght.turb[i]);
        }
    }
    version(multi_species_gas) {
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) {
                F.vec[cqi.species+i] += factor*(aL*rL*CL*Lft.gas.massf[i] + aR*rR*CR*Rght.gas.massf[i]);
            }
        }
    }
    version(multi_T_gas) {
        foreach (i; 0 .. cqi.n_modes) {
            F.vec[cqi.modes+i] +=  factor*(aL*rL*CL*Lft.gas.u_modes[i] + aR*rR*CR*Rght.gas.u_modes[i]);
        }
    }
} // end ldfss0()

@nogc
void ldfss2(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0)
// Jack Edwards' LDFSS (variant 2) flux calculator.
//
// Implemented from details in
//     Jack R. Edwards (1997)
//     A low-diffusion flux-splitting scheme for Navier-Stokes calculations.
//     Computers & Fluids paper.
//
{
    auto gmodel = myConfig.gmodel;
    // Unpack the flow-state vectors for either side of the interface.
    // Store in work vectors, those quantities that will be neede later.
    number rL = Lft.gas.rho;
    number pL = Lft.gas.p;
    number pLrL = pL / rL;
    number uL = Lft.vel.x;
    number vL = Lft.vel.y;
    number wL = Lft.vel.z;
    number eL = gmodel.internal_energy(Lft.gas);
    number aL = Lft.gas.a;
    number keL = 0.5*(uL*uL + vL*vL + wL*wL);
    number HL = eL + pLrL + keL;
    version(turbulence) { HL += myConfig.turb_model.turbulent_kinetic_energy(Lft); }
    //
    number rR = Rght.gas.rho;
    number pR = Rght.gas.p;
    number pRrR = pR / rR;
    number uR = Rght.vel.x;
    number vR = Rght.vel.y;
    number wR = Rght.vel.z;
    number eR = gmodel.internal_energy(Rght.gas);
    number aR = Rght.gas.a;
    number keR = 0.5*(uR*uR + vR*vR + wR*wR);
    number HR = eR + pRrR + keR;
    version(turbulence) { HR += myConfig.turb_model.turbulent_kinetic_energy(Rght); }
    //
    // Common sound speed (eqn 33) and Mach numbers (eqn 34) for LDFSS(2)
    number am = 0.5*(aL+aR);
    number ML = uL / am;
    number MR = uR / am;
    // Split Mach number (eqn 15)
    number MpL = 0.25*(ML + 1.0)^^2;
    number MmR = -0.25*(MR - 1.0)^^2;
    // Parameters to provide correct sonic-point transition behaviour
    // equation 16
    number alphaL = 0.5*(1.0 + sgn(ML.re));
    number alphaR = 0.5*(1.0 - sgn(MR.re));
    // equation 17
    number betaL = -fmax(0.0, 1.0-floor(fabs(ML.re)));
    number betaR = -fmax(0.0, 1.0-floor(fabs(MR.re)));
    // subsonic pressure splitting (eqn 12)
    number PL = 0.25*(ML+1.0)^^2*(2.0-ML);
    number PR = 0.25*(MR-1.0)^^2*(2.0+MR);
    // D parameter (eqn 11)
    number DL = alphaL*(1.0+betaL) - betaL*PL;
    number DR = alphaR*(1.0+betaR) - betaR*PR;
    // M_1/2 parameters for LDFSS (1,2) (eqn 20 & eqn 28 & eqn 29)
    number delta = 1.0; // weighting parameter to suppress 'carbuncle' phenomena
                        // while preserving the beneficial traits of the scheme
                        // in the capturing of discontinuities. Choice of delta
                        // is not obvious. Higher values are better at 'carbuncle'
                        // supression (favourable for blunt-body flows), but can also
                        // cause smearing of oblique shocks.
    number Mhalf = 0.25*betaL*betaR*(sqrt(0.5*(ML^^2+MR^^2))-1.0)^^2;
    number MhalfL = Mhalf * (2*pR/(pL+pR) - delta*(fabs(pL-pR)/pL));
    number MhalfR = Mhalf * (2*pL/(pL+pR) - delta*(fabs(pL-pR)/pR));
    // C parameter for LDFSS (2) (eqn 13 & eqn 14 & eqn 26 & eqn 27)
    number CL = alphaL*(1.0+betaL)*ML - betaL*MpL - MhalfL;
    number CR = alphaR*(1.0+betaR)*MR - betaR*MmR + MhalfR;
    //
    // Assemble components of the flux vector.
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    number ru_half = am*rL*CL + am*rR*CR;
    number ru2_half = am*rL*CL*uL + am*rR*CR*uR;
    number p_half = DL*pL + DR*pR;
    F.vec[cqi.mass] += factor*ru_half;
    F.vec[cqi.xMom] += factor*(ru2_half+p_half);
    F.vec[cqi.yMom] += factor*(am*rL*CL*vL + am*rR*CR*vR);
    if (cqi.threeD) { F.vec[cqi.zMom] += factor*(am*rL*CL*wL + am*rR*CR*wR); }
    F.vec[cqi.totEnergy] += factor*(am*rL*CL*HL + am*rR*CR*HR);
    version(turbulence) {
        foreach(i; 0 .. myConfig.turb_model.nturb) {
            F.vec[cqi.rhoturb+i] += factor*(am*rL*CL*Lft.turb[i] + am*rR*CR*Rght.turb[i]);
        }
    }
    version(multi_species_gas) {
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) {
                F.vec[cqi.species+i] += factor*(am*rL*CL*Lft.gas.massf[i] + am*rR*CR*Rght.gas.massf[i]);
            }
        }
    }
    version(multi_T_gas) {
        foreach (i; 0 .. cqi.n_modes) {
            F.vec[cqi.modes+i] +=  factor*(am*rL*CL*Lft.gas.u_modes[i] + am*rR*CR*Rght.gas.u_modes[i]);
        }
    }
} // end ldfss2()

@nogc
void hanel(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0)
// Hanel's flux calculator.
//
// Implemented from Y. Wada and M. S. Liou details in their AIAA paper
//     Y. Wada and M. -S. Liou (1997)
//     An accurate and robust flux splitting scheme for shock and contact discontinuities.
// with reference to....
//    Hanel, Schwane, & Seider's 1987 paper
//    On the accuracy of upwind schemes for the solution of the Navier-Stokes equations
//
{
    auto gmodel = myConfig.gmodel;
    // Unpack the flow-state vectors for either side of the interface.
    // Store in work vectors, those quantities that will be neede later.
    number rL = Lft.gas.rho;
    number pL = Lft.gas.p;
    number pLrL = pL / rL;
    number uL = Lft.vel.x;
    number vL = Lft.vel.y;
    number wL = Lft.vel.z;
    number eL = gmodel.internal_energy(Lft.gas);
    number aL = Lft.gas.a;
    number keL = 0.5*(uL*uL + vL*vL + wL*wL);
    number HL = eL + pLrL + keL;
    version(turbulence) { HL += myConfig.turb_model.turbulent_kinetic_energy(Lft); }
    //
    number rR = Rght.gas.rho;
    number pR = Rght.gas.p;
    number pRrR = pR / rR;
    number uR = Rght.vel.x;
    number vR = Rght.vel.y;
    number wR = Rght.vel.z;
    number eR = gmodel.internal_energy(Rght.gas);
    number aR = Rght.gas.a;
    number keR = 0.5*(uR*uR + vR*vR + wR*wR);
    number HR = eR + pRrR + keR;
    version(turbulence) { HR += myConfig.turb_model.turbulent_kinetic_energy(Rght); }
    //
    number am = fmax(aL, aR);
    number ML = uL / am;
    number MR = uR / am;
    // Left state:
    // pressure splitting (eqn 7)
    // and velocity splitting (eqn 9)
    number pLplus, uLplus;
    if (fabs(uL) <= aL) {
        uLplus = 1.0/(4.0*aL) * (uL+aL)*(uL+aL);
        pLplus = pL*uLplus * (1.0/aL * (2.0-uL/aL));
    } else {
        uLplus = 0.5*(uL+fabs(uL));
        pLplus = pL*uLplus * (1.0/uL);
    }
    // Right state:
    // pressure splitting (eqn 7)
    // and velocity splitting (eqn 9)
    number pRminus, uRminus;
    if (fabs(uR) <= aR) {
        uRminus = -1.0/(4.0*aR) * (uR-aR)*(uR-aR);
        pRminus = pR*uRminus * (1.0/aR * (-2.0-uR/aR));
    } else {
        uRminus = 0.5*(uR-fabs(uR));
        pRminus = pR*uRminus * (1.0/uR);
    }
    // The mass flux is relative to the moving interface.
    number ru_half = uLplus * rL + uRminus * rR;
    number ru2_half = uLplus * rL * uL + uRminus * rR * uR;
    // Pressure flux (eqn 8)
    number p_half = pLplus + pRminus;
    // Assemble components of the flux vector (eqn 36).
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    F.vec[cqi.mass] += factor*(uLplus * rL + uRminus * rR);
    F.vec[cqi.xMom] += factor*(uLplus * rL * uL + uRminus * rR * uR + p_half);
    F.vec[cqi.yMom] += factor*(uLplus * rL * vL + uRminus * rR * vR);
    if (cqi.threeD) { F.vec[cqi.zMom] += factor*(uLplus * rL * wL + uRminus * rR * wR); }
    F.vec[cqi.totEnergy] += factor*(uLplus * rL * HL + uRminus * rR * HR);
    version(turbulence) {
        foreach(i; 0 .. myConfig.turb_model.nturb) {
            F.vec[cqi.rhoturb+i] += factor*(uLplus * rL * Lft.turb[i] + uRminus * rR * Rght.turb[i]);
        }
    }
    version(multi_species_gas) {
        if (cqi.n_species > 1) {
            foreach (i; 0 .. cqi.n_species) {
                F.vec[cqi.species+i] += factor*(uLplus*rL*Lft.gas.massf[i] + uRminus*rR*Rght.gas.massf[i]);
            }
        }
    }
    version(multi_T_gas) {
        foreach (i; 0 .. cqi.n_modes) {
            F.vec[cqi.modes+i] += factor*(uLplus*rL*Lft.gas.u_modes[i] + uRminus*rR*Rght.gas.u_modes[i]);
        }
    }
} // end hanel()

@nogc
void efmflx(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0)
/** \brief Compute the fluxes across an interface using
 * the Equilibrium Flux Method of Macrossan & Pullin
 *
 * \param Lft    : IN     : array of Left flow states
 *     (with velocities in local frame of reference)
 * \param Rght   : IN     : array of Right flow state
 * \param IF     : IN/OUT : array of interface flux data structures
 *
 * \verbatim
 * interface data -- contains...
 *     flux of mass across the interface (kg/s/m**2)
 *     flux of normal momentum
 *     flux of tangential momentum
 *     flux of energy
 *     array of species fluxes
 *     vibrational energies
 *     free-electron energy
 * \endverbatim
 */
{
    auto gmodel = myConfig.gmodel;
    // Local variable names reflect the names used in the original FORTRAN code by MNM.
    const double PHI = 1.0;
    number vnL, vpL, vnR, vpR, vqL, vqR;
    number rtL, cmpL, rtR, cmpR;
    number hvsqL, hvsqR;
    number wL, wR, dL, dR;
    number rhoL, rhoR, presL, presR, tR, tL;
    number eL, eR, hL, hR;
    number snL, snR, exL, exR, efL, efR;
    number fmsL, fmsR;
    number cv, cp, con, gam, Rgas;
    number cvL, cvR, RgasL, RgasR;
    number rLsqrt, rRsqrt, alpha;
    number mass_flux;
    int statusf;
    //
    // Calculate Constants
    // dtwspi = 1.0 / (2.0 * sqrt ( 3.14159265359 ));
    const double dtwspi = 0.282094792;
    // Unpack Left flow state.
    rhoL = Lft.gas.rho;
    presL = Lft.gas.p;
    eL = gmodel.internal_energy(Lft.gas);
    hL = eL + presL/rhoL;
    version(turbulence) { hL += myConfig.turb_model.turbulent_kinetic_energy(Lft); }
    // bundle turbulent energy, PJ 2017-06-17
    tL = Lft.gas.T;
    vnL = Lft.vel.x;
    vpL = Lft.vel.y;
    vqL = Lft.vel.z;
    // Unpack Right flow state.
    rhoR = Rght.gas.rho;
    presR = Rght.gas.p;
    eR = gmodel.internal_energy(Rght.gas);
    hR = eR + presR/rhoR;
    version(turbulence) { hR += myConfig.turb_model.turbulent_kinetic_energy(Rght); }
    tR = Rght.gas.T;
    vnR = Rght.vel.x;
    vpR = Rght.vel.y;
    vqR = Rght.vel.z;
    // Derive the gas "constants" from the local conditions.
    cvL = gmodel.Cv(Lft.gas);
    RgasL = presL / (rhoL * tL);
    cvR = gmodel.Cv(Rght.gas);
    RgasR = presR / (rhoR * tR);
    rLsqrt = sqrt(rhoL);
    rRsqrt = sqrt(rhoR);
    alpha = rLsqrt / (rLsqrt + rRsqrt);
    cv = alpha * cvL + (1.0 - alpha) * cvR;
    Rgas = alpha * RgasL + (1.0 - alpha) * RgasR;
    cp = cv + Rgas;
    gam = cp / cv;
    //
    // Start EFM calculation proper.
    con = 0.5 * (gam + 1.0) / (gam - 1.0);
    //
    rtL = Rgas * tL;
    cmpL = sqrt(2.0 * rtL);
    hvsqL = 0.5 * (vnL * vnL + vpL * vpL + vqL * vqL);
    snL = vnL / (PHI * cmpL);
    exxef(snL, exL, efL);
    wL = 0.5 * (1.0 + efL);
    dL = exL * dtwspi;
    //
    rtR = presR / rhoR;
    cmpR = sqrt(2.0 * rtR);
    hvsqR = 0.5 * (vnR * vnR + vpR * vpR + vqR * vqR);
    snR = vnR / (PHI * cmpR);
    exxef(snR, exR, efR);
    wR = 0.5 * (1.0 - efR);
    dR = -exR * dtwspi;
    //
    // Combine the fluxes.
    fmsL = (wL * rhoL * vnL) + (dL * cmpL * rhoL);
    fmsR = (wR * rhoR * vnR) + (dR * cmpR * rhoR);
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    mass_flux = factor*(fmsL + fmsR);
    F.vec[cqi.mass] += mass_flux;
    F.vec[cqi.xMom] += factor*(fmsL*vnL + fmsR*vnR + wL*presL + wR*presR);
    F.vec[cqi.yMom] += factor*(fmsL*vpL + fmsR*vpR);
    if (cqi.threeD) { F.vec[cqi.zMom] += factor*(fmsL*vqL + fmsR*vqR); }
    F.vec[cqi.totEnergy] += factor*((wL * rhoL * vnL) * (hvsqL + hL) +
                                    (wR * rhoR * vnR) * (hvsqR + hR) +
                                    (dL * cmpL * rhoL) * (hvsqL + con * rtL) +
                                    (dR * cmpR * rhoR) * (hvsqR + con * rtR));
    // Species mass flux and individual energies.
    // Presently, this is implemented by assuming that
    // the wind is blowing one way or the other and then
    // picking the appropriate side for the species fractions.
    // Such an approach may not be fully compatible with the
    // EFM approach where there can be fluxes from both sides.
    if (mass_flux > 0.0) {
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] += mass_flux * Lft.turb[i]; }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] += mass_flux * Lft.gas.massf[i]; }
            }
        }
        version(multi_T_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] += mass_flux * Lft.gas.u_modes[i]; }
            }
        }
        // NOTE: - the following relies on the free-electron mode being the last mode
        //       - for single temp models F_renergies isn't used
        //       - for multitemp modes with no free-electrons p_e is zero
        // Add electron pressure work term onto final energy mode
        // F.energies[$-1] += mass_flux * Lft.gas.p_e / Lft.gas.rho; [TODO]
    } else {
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] +=  mass_flux * Rght.turb[i]; }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] += mass_flux * Rght.gas.massf[i]; }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] += mass_flux * Rght.gas.u_modes[i]; }
        }
    }
} // end efmflx()

@nogc
void exxef(number sn, ref number exx, ref number ef)
/** \brief Compute exp(-x**2) and erf(x) with a polynomial approximation.
 *
 * \param sn   : IN  : x
 * \param &exx : OUT : exp(x**2)
 * \param &ef  : OUT : erf(x)  error function
 */
{
    number snsq, ef1, y;
    //
    const double P = 0.327591100;
    const double A1 = 0.254829592;
    const double A2 = -0.284496736;
    const double A3 = 1.421413741;
    const double A4 = -1.453152027;
    const double A5 = 1.061405429;
    const double LIMIT = 5.0;
    const double EXLIM = 0.138879e-10;
    const double EFLIM = 1.0;
    //
    //#   define DSIGN(val,sgn) ( (sgn >= 0.0)? fabs(val): -fabs(val) )
    //
    if (fabs(sn) > LIMIT) {
        exx = EXLIM;
        ef1 = EFLIM;
    } else {
        snsq = sn * sn;
        exx = exp(-snsq);
        y = 1.0 / (1.0 + P * fabs(sn));
        ef1 = 1.0 - y * (A1 + y * (A2 + y * (A3 + y * (A4 + A5 * y)))) * exx;
    }
    ef = copysign(ef1, sn);
} // end exxef

@nogc
void adaptive_efm_ausmdv(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig)
// This adaptive flux calculator uses uses the Equilibrium Flux Method
// near shocks and AUSMDV away from shocks, however, we really don't want
// EFM to be used across interfaces with strong shear.
// EFM should still be able to do it's work as we really needed it for the
// situations where the shock is closely aligned with the grid.
// In that situation, we don't expect a stong shear at the interface.
//
// The actual work is passed off to the original flux calculation functions.
{
    number alpha = IFace.fs.S;
    if (alpha > 0.0) {
        efmflx(Lft, Rght, IFace, myConfig, alpha);
    }
    if (alpha < 1.0) {
        ausmdv(Lft, Rght, IFace, myConfig, 1.0-alpha);
    }
}

@nogc
void adaptive_hanel_ausmdv(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig)
// This adaptive flux calculator uses the Hanel flux calculator
// near shocks and AUSMDV away from shocks.
//
// The actual work is passed off to the original flux calculation functions.
{
    number alpha = IFace.fs.S;
    if (alpha > 0.0) {
        hanel(Lft, Rght, IFace, myConfig, alpha);
    }
    if (alpha < 1.0) {
        ausmdv(Lft, Rght, IFace, myConfig, 1.0-alpha);
    }
}

@nogc
void adaptive_hanel_ausm_plus_up(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig)
// This adaptive flux calculator uses the Hanel flux calculator
// near shocks and AUSM+up away from shocks.
//
// The actual work is passed off to the original flux calculation functions.
{
    number alpha = IFace.fs.S;
    if (alpha > 0.0) {
        hanel(Lft, Rght, IFace, myConfig, alpha);
    }
    if (alpha < 1.0) {
        ausm_plus_up(Lft, Rght, IFace, myConfig, 1.0-alpha);
    }
}

@nogc
void adaptive_ldfss0_ldfss2(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig)
// This adaptive flux calculator uses the Hanel flux calculator
// near shocks and AUSMDV away from shocks.
//
// The actual work is passed off to the original flux calculation functions.
{
    number alpha = IFace.fs.S;
    if (alpha > 0.0) {
        ldfss0(Lft, Rght, IFace, myConfig, alpha);
    }
    if (alpha < 1.0) {
        ldfss2(Lft, Rght, IFace, myConfig, 1.0-alpha);
    }
}

@nogc
void adaptive_hlle_hllc(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig)
// This adaptive flux calculator uses the standard HLLE flux calculator
// near shocks and HLLC away from shocks.
//
// The actual work is passed off to the original flux calculation functions.
{
    number alpha = IFace.fs.S;
    if (alpha > 0.0) {
        hlle2(Lft, Rght, IFace, myConfig, alpha);
    }
    if (alpha < 1.0) {
        hllc(Lft, Rght, IFace, myConfig, 1.0-alpha);
    }
}

@nogc
void adaptive_hlle_roe(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig)
// This adaptive flux calculator uses uses the standard HLLE flux calculator
// near shocks and Roe away from shocks.
//
// The actual work is passed off to the original flux calculation functions.
{
    number alpha = IFace.fs.S;
    if (alpha > 0.0) {
        hlle2(Lft, Rght, IFace, myConfig, alpha);
    }
    if (alpha < 1.0) {
        roe(Lft, Rght, IFace, myConfig, 1.0-alpha);
    }
}

@nogc
void ausm_plus_up(in FlowState Lft, in FlowState Rght, ref FVInterface IFace,
                  ref LocalConfig myConfig, number factor=1.0)
// Liou's 2006 AUSM+up flux calculator
//
// A new version of the AUSM-family schemes, based
// on the low Mach number asymptotic analysis.
// Ironically, this flux calculator causes simulations
// initialised with 0.0 m/s velocities to crash.
//
// RJG -- 26-Apr-2013
// Added a (+ EPSILON) to help with any divide by zero problems.
// That being said, I'm not sure this helps with the
// crashes at zero velocity because it would seem that the flow
// of control would pass through a different branch for these cases.
//
// M. -S. Liou (2006)
// A sequel to AUSM, Part II: AUSM+-up for all speeds
// Journal of Computational Physics, Vol 214, pp 137-170
//
// This code: W. Y. K. Chan & P. A. Jacobs
{
    auto gmodel = myConfig.gmodel;
    // Some helper functions
    @nogc number M1plus(number M) { return 0.5*(M + fabs(M)); }
    @nogc number M1minus(number M) { return 0.5*(M - fabs(M)); }
    @nogc number M2plus(number M) { return 0.25*(M + 1.0)*(M + 1.0); }
    @nogc number M2minus(number M) { return -0.25*(M - 1.0)*(M - 1.0); }
    @nogc number M4plus(number M, number beta) {
        if ( fabs(M) >= 1.0 ) {
            return M1plus(M);
        } else {
            number M2p = M2plus(M);
            number M2m = M2minus(M);
            return M2p*(1.0 - 16.0*beta*M2m);
        }
    }
    @nogc number M4minus(number M, number beta) {
        if ( fabs(M) >= 1.0 ) {
            return M1minus(M);
        } else {
            number M2p = M2plus(M);
            number M2m = M2minus(M);
            return M2m*(1.0 + 16.0*beta*M2p);
        }
    }
    @nogc number P5plus(number M, number alpha) {
        if ( fabs(M) >= 1.0 ) {
            return (1.0/M)*M1plus(M);
        } else {
            number M2p = M2plus(M);
            number M2m = M2minus(M);
            return M2p*((2.0 - M) - 16.0*alpha*M*M2m);
        }
    }
    @nogc number P5minus(number M, number alpha) {
        if ( fabs(M) >= 1.0 ) {
            return (1.0/M)*M1minus(M);
        } else {
            number M2p = M2plus(M);
            number M2m = M2minus(M);
            return M2m*((-2.0 - M) + 16.0*alpha*M*M2p);
        }
    }
    // Unpack the flow-state vectors for either side of the interface.
    // Store in work vectors, those quantities that will be neede later.
    double M_inf = myConfig.M_inf;

    number rL = Lft.gas.rho;
    number pL = Lft.gas.p;
    number uL = Lft.vel.x;
    number vL = Lft.vel.y;
    number wL = Lft.vel.z;
    number eL = gmodel.internal_energy(Lft.gas);
    number aL = Lft.gas.a;
    number keL = 0.5 * (uL * uL + vL * vL + wL * wL);
    number HL = eL + pL/rL + keL;
    version(turbulence) { HL += myConfig.turb_model.turbulent_kinetic_energy(Lft); }
    //
    number rR = Rght.gas.rho;
    number pR = Rght.gas.p;
    number uR = Rght.vel.x;
    number vR = Rght.vel.y;
    number wR = Rght.vel.z;
    number eR = gmodel.internal_energy(Rght.gas);
    number aR = Rght.gas.a;
    number keR = 0.5 * (uR * uR + vR * vR + wR * wR);
    number HR = eR + pR/rR + keR;
    version(turbulence) { HR += myConfig.turb_model.turbulent_kinetic_energy(Rght); }
    //
    // This is the main part of the flux calculator.
    //
    // Interface sound speed (eqns 28 & 30).
    // An approximation is used instead of these equations as
    // suggested by Liou in his paper (see line below eqn 69).
    number a_half = 0.5 * (aR + aL);
    // Left and right state Mach numbers (eqn 69).
    number ML = uL / a_half;
    number MR = uR / a_half;
    // Mean local Mach number (eqn 70).
    number MbarSq = (uL*uL + uR*uR) / (2.0 * a_half *a_half);
    // Reference Mach number (eqn 71).
    number M0Sq = fmin(1.0, fmax(MbarSq, M_inf*M_inf));
     // Some additional parameters.
    number fa = sqrt(M0Sq) * (2.0 - sqrt(M0Sq));   // eqn 72
    number alpha = 0.1875 * (-4.0 + 5 * fa * fa);  // eqn 76
    number beta = 0.125;                           // eqn 76
    // Left state:
    // M4plus(ML)
    // P5plus(ML)
    number M4plus_ML = M4plus(ML, beta);
    number P5plus_ML = P5plus(ML, alpha);
    // Right state:
    // M4minus(MR)
    // P5minus(MR)
    number M4minus_MR = M4minus(MR, beta);
    number P5minus_MR = P5minus(MR, alpha);
    // Pressure diffusion modification for
    // mass flux (eqn 73) and pressure flux (eqn 75).
    const double KP = 0.25;
    const double KU = 0.75;
    const double SIGMA = 1.0;
    number r_half = 0.5*(rL + rR);
    number Mp = -KP / fa * fmax((1.0 - SIGMA * MbarSq), 0.0) * (pR - pL) / (r_half*a_half*a_half);
    number Pu = -KU * P5plus_ML * P5minus_MR * (rL + rR) * fa * a_half * (uR - uL);
    // Mass Flux (eqns 73 & 74).
    number M_half = M4plus_ML + M4minus_MR + Mp;
    number ru_half = a_half * M_half;
    if ( M_half > 0.0 ) {
       ru_half *= rL;
    } else {
       ru_half *= rR;
    }
    // Pressure flux (eqn 75).
    number p_half = P5plus_ML*pL + P5minus_MR*pR + Pu;
    // Momentum flux: normal direction
    number ru2_half;
    if (ru_half >= 0.0) {
        ru2_half = ru_half * uL;
    } else {
        ru2_half = ru_half * uR;
    }

    number mass_flux = factor*ru_half;
    // Assemble components of the flux vector.
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    F.vec[cqi.mass] += mass_flux;
    if (ru_half >= 0.0) {
        // Wind is blowing from the left.
        F.vec[cqi.xMom] += factor*(ru2_half+p_half);
        F.vec[cqi.yMom] += factor*(ru_half*vL);
        if (cqi.threeD) { F.vec[cqi.zMom] += factor*(ru_half*wL); }
        F.vec[cqi.totEnergy] += mass_flux * HL;
        version(turbulence) {
            foreach(i; 0 ..  myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] += mass_flux * Lft.turb[i]; }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] += mass_flux * Lft.gas.massf[i]; }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] += mass_flux * Lft.gas.u_modes[i]; }
        }
        // NOTE: - the following relies on the free-electron mode being the last mode
        //       - for single temp models F_renergies isn't used
        //       - for multitemp modes with no free-electrons p_e is zero
        // Add electron pressure work term onto final energy mode
        // F.energies[nmodes-1] += ru_half * Lft.gas.p_e / Lft.gas.rho;
    } else {
        // Wind is blowing from the right.
        F.vec[cqi.xMom] += factor*(ru2_half+p_half);
        F.vec[cqi.yMom] += factor*(ru_half*vR);
        if (cqi.threeD) { F.vec[cqi.zMom] += factor*(ru_half*wR); }
        F.vec[cqi.totEnergy] += mass_flux * HR;
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] += mass_flux * Rght.turb[i]; }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] += mass_flux * Rght.gas.massf[i]; }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] += mass_flux * Rght.gas.u_modes[i]; }
        }
    }
} // end ausm_plus_up()

@nogc
void hlle(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0)
// HLLE fluxes for MHD.
// From V. Wheatley Matlab implementation
// Author D. M. Bond
// Port to D by PJ, 2014-07-24
{
    auto gmodel = myConfig.gmodel;
    @nogc number SAFESQRT(number x) { return (fabs(x)>1.0e-14) ? sqrt(x) : to!number(0.0); }
    // Unpack the flow-state vectors for either side of the interface.
    // Store in work vectors, those quantities that will be neede later.
    number rL = Lft.gas.rho;
    number pL = Lft.gas.p;
    number uL = Lft.vel.x;
    number vL = Lft.vel.y;
    number wL = Lft.vel.z;
    version(MHD) {
        number BxL = Lft.B.x;
        number ByL = Lft.B.y;
        number BzL = Lft.B.z;
    }
    number rR = Rght.gas.rho;
    number pR = Rght.gas.p;
    number uR = Rght.vel.x;
    number vR = Rght.vel.y;
    number wR = Rght.vel.z;
    version(MHD) {
        number BxR = Rght.B.x;
        number ByR = Rght.B.y;
        number BzR = Rght.B.z;
    }
    //
    // Derive the gas "constants" from the local conditions.
    number cvL = gmodel.Cv(Lft.gas);
    number RgasL = gmodel.R(Lft.gas);
    number cvR = gmodel.Cv(Rght.gas);
    number RgasR = gmodel.R(Rght.gas);
    number rLsqrt = sqrt(rL);
    number rRsqrt = sqrt(rR);
    number alpha = rLsqrt / (rLsqrt + rRsqrt);
    number cv = alpha * cvL + (1.0 - alpha) * cvR;
    number Rgas = alpha * RgasL + (1.0 - alpha) * RgasR;
    number cp = cv + Rgas;
    number gam = cp / cv;
    //
    // Compute Roe Average State (currently simple average)
    number rho = 0.5*(rL+rR);
    number p   = 0.5*(pL+pR);
    number u   = 0.5*(uL+uR);
    //v   = 0.5*(vL+vR);
    //w   = 0.5*(wL+wR);
    version(MHD) {
        number Bx  = 0.5*(BxL+BxR);
        number By  = 0.5*(ByL+ByR);
        number Bz  = 0.5*(BzL+BzR);
    }
    //
    // Compute Eigenvalues of Roe Matrix
    //u2=u*u;
    //v2=v*v;
    //w2=w*w;
    //uu=u2+v2+w2;
    version(MHD) {
        number a2 = gam*p/rho;
        number Bx2 = Bx*Bx;
        number Bt2 = By*By + Bz*Bz;
        number BB = Bx2 + Bt2;
        number ca2 = Bx2/rho;
        number alf = a2+BB/rho;
        number als = SAFESQRT(alf*alf-4.0*a2*ca2);
        number cf2 = 0.5*(alf+als);
        number cf = sqrt(cf2);
        number wp = u+cf;
        number wm = u-cf;
        //
        // Compute the Jump in Conserved Variables between L and R
        number BxL2 = BxL*BxL;
        number BtL2 = ByL*ByL + BzL*BzL;
        number BBL = BxL2 + BtL2;
        number ptL = pL + 0.5*BBL;
        number uL2 = uL*uL;
        number uuL = uL2 + vL*vL + wL*wL;
        number aL2 = gam*pL/rL;
        number caL2 = BxL2/rL;
        number alfL = aL2+BBL/rL;
        number alsL = SAFESQRT(alfL*alfL-4.0*aL2*caL2);
        number cfL2 = 0.5*(alfL+alsL);
        number cfL = sqrt(cfL2);
        //wpL = uL+cfL;
        number wmL = uL-cfL;
        number BxR2 = BxR*BxR;
        number BtR2 = ByR*ByR + BzR*BzR;
        number BBR = BxR2 + BtR2;
        number ptR = pR + 0.5*BBR;
        number uR2 = uR*uR;
        number uuR = uR2 + vR*vR + wR*wR;
        number aR2 = gam*pR/rR;
        number caR2 = BxR2/rR;
        number alfR = aR2+BBR/rR;
        number alsR = SAFESQRT(alfR*alfR-4.0*aR2*caR2);
        number cfR2 = 0.5*(alfR+alsR);
        number cfR = sqrt(cfR2);
        number wpR = uR+cfR;
        //wmR = uR-cfR;

        number[8] dU;
        dU[0] = rR - rL;
        dU[1] = rR*uR - rL*uL;
        dU[2] = rR*vR - rL*vL;
        dU[3] = rR*wR - rL*wL;
        dU[4] = BxR - BxL;
        dU[5] = ByR - ByL;
        dU[6] = BzR - BzL;
        dU[7] = (pR - pL)/(gam-1.0) + 0.5*(rR*uuR+BBR) - 0.5*(rL*uuL+BBL);
        //
        number bl = fmin(wmL, wm);
        number br = fmax(wpR, wp);
        number blm = fmin(bl, 0.0);
        number brp = fmax(br, 0.0);
        number fmassL = rL*uL;
        number fmassR = rR*uR;
        number fmomxL = rL*uL2 - BxL2 + ptL;
        number fmomxR = rR*uR2 - BxR2 + ptR;
        number fmomyL = rL*uL*vL - BxL*ByL;
        number fmomyR = rR*uR*vR - BxR*ByR;
        number fmomzL = rL*uL*wL - BxL*BzL;
        number fmomzR = rR*uR*wR - BxR*BzR;
        number fBxL = 0.0;
        number fBxR = 0.0;
        number fByL = uL*ByL - vL*BxL;
        number fByR = uR*ByR - vR*BxR;
        number fBzL = uL*BzL - wL*BxL;
        number fBzR = uR*BzR - wR*BxR;
        number fenergyL = (pL/(gam-1.0)+0.5*(rL*uuL+BBL)+ptL)*uL - (uL*BxL+vL*ByL+wL*BzL)*BxL;
        number fenergyR = (pR/(gam-1.0)+0.5*(rR*uuR+BBR)+ptR)*uR - (uR*BxR+vR*ByR+wR*BzR)*BxR;
        number iden = 1.0/(brp - blm);
        number fac1 = brp*blm;
        //
        ConservedQuantities F = IFace.F;
        auto cqi = myConfig.cqi;
        number mass_flux = factor*(brp*fmassL - blm*fmassR + fac1*dU[0])*iden;
        F.vec[cqi.mass] += mass_flux;
        F.vec[cqi.xMom] += factor*((brp*fmomxL - blm*fmomxR + fac1*dU[1])*iden);
        F.vec[cqi.yMom] += factor*((brp*fmomyL - blm*fmomyR + fac1*dU[2])*iden);
        if (cqi.threeD) { F.vec[cqi.zMom] += factor*((brp*fmomzL - blm*fmomzR + fac1*dU[3])*iden); }
        F.vec[cqi.totEnergy] += factor*(brp*fenergyL - blm*fenergyR + fac1*dU[7])*iden;
        if (cqi.MHD) {
            F.vec[cqi.xB] += factor*((brp*fBxL - blm*fBxR + fac1*dU[4])*iden);
            F.vec[cqi.yB] += factor*((brp*fByL - blm*fByR + fac1*dU[5])*iden);
            F.vec[cqi.zB] += factor*((brp*fBzL - blm*fBzR + fac1*dU[6])*iden);
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) {
                    F.vec[cqi.species+i] += mass_flux * ((mass_flux >= 0.0) ? Lft.gas.massf[i]: Rght.gas.massf[i]);
                }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) {
                F.vec[cqi.modes+i] += mass_flux * ((mass_flux >= 0.0) ? Lft.gas.u_modes[i]: Rght.gas.u_modes[i]);
            }
        }
    } else {
        assert(0, "HLLE not implemented for normal gas dynamics");
    }
} // end hlle()

@nogc
void hlle2(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0)
// Einfedlt's HLLE flux calculator.
//
// Implemented from details in
//     B. Einfeldt, C. D. Munz, P. L. Roe, and B. Sjogreen
//     On Godunov-Type Methods near Low Densities
//     Journal of Computational Physics (1991)
// and
//     B. Einfeldt
//     On Godunov-Type Methods for Gas Dynamics
//     SIAM Journal Numerical Analysis (1988)
//
{
    auto gmodel = myConfig.gmodel;
    // Unpack the flow-state vectors for either side of the interface.
    // Store in work vectors, those quantities that will be needed later.
    number gL = gmodel.gamma(Lft.gas);
    number rL = Lft.gas.rho;
    number pL = Lft.gas.p;
    number pLrL = pL / rL;
    number uL = Lft.vel.x;
    number vL = Lft.vel.y;
    number wL = Lft.vel.z;
    number eL = gmodel.internal_energy(Lft.gas);
    number aL = Lft.gas.a;
    number keL = 0.5*(uL*uL + vL*vL + wL*wL);
    number HL = eL + pLrL + keL;
    version(turbulence) { HL += myConfig.turb_model.turbulent_kinetic_energy(Lft); }
    //
    number gR = gmodel.gamma(Rght.gas);
    number rR = Rght.gas.rho;
    number pR = Rght.gas.p;
    number pRrR = pR / rR;
    number uR = Rght.vel.x;
    number vR = Rght.vel.y;
    number wR = Rght.vel.z;
    number eR = gmodel.internal_energy(Rght.gas);
    number aR = Rght.gas.a;
    number keR = 0.5*(uR*uR + vR*vR + wR*wR);
    number HR = eR + pRrR + keR;
    version(turbulence) { HR += myConfig.turb_model.turbulent_kinetic_energy(Rght); }
    //

    // compute Roe-average state
    number uhat = (sqrt(rL)*uL+sqrt(rR)*uR) / (sqrt(rL) + sqrt(rR));
    number ghat = (sqrt(rL)*gL+sqrt(rR)*gR) / (sqrt(rL) + sqrt(rR));    
    number ahat2 = ((sqrt(rL)*aL*aL+sqrt(rR)*aR*aR) / (sqrt(rL) + sqrt(rR))) + 0.5*(ghat-1.0)*((sqrt(rL)+sqrt(rR)) / sqrt((sqrt(rL) + sqrt(rR))))*(uR-uL)*(uR-uL);
    number ahat = sqrt(ahat2);

    // compute wave speed estimates
    number SLm = fmin(uL-aL, uhat-ahat);
    number SRp = fmax(uR+aR, uhat+ahat);

    // compute HLLE flux
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    if (SLm >= 0) {
        //Right-going supersonic flow
        F.vec[cqi.mass] += factor*(rL*uL);
        F.vec[cqi.xMom] += factor*(rL*uL*uL+pL);
        F.vec[cqi.yMom] += factor*(rL*uL*vL);
        if (cqi.threeD) { F.vec[cqi.zMom] += factor*(rL*uL*wL); }
        F.vec[cqi.totEnergy] += factor*(rL*uL*HL);
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) {
                F.vec[cqi.rhoturb+i] += factor*(rL*uL*Lft.turb[i]);
            }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) {
                    F.vec[cqi.species+i] += factor*(rL*uL*Lft.gas.massf[i]);
                }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) {
                F.vec[cqi.modes+i] += factor*(rL*uL*Lft.gas.u_modes[i]);
            }
        }
    } else if (SRp <= 0) {
        // Left-going supersonic flow
        F.vec[cqi.mass] += factor*(rR*uR);
        F.vec[cqi.xMom] += factor*(rR*uR*uR+pR);
        F.vec[cqi.yMom] += factor*(rR*uR*vR);
        if (cqi.threeD) { F.vec[cqi.zMom] += factor*(rR*uR*wR); }
        F.vec[cqi.totEnergy] += factor*(rR*uR*HR);
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) {
                F.vec[cqi.rhoturb+i] += factor*(rR*uR*Rght.turb[i]);
            }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) {
                    F.vec[cqi.species+i] += factor*(rR*uR*Rght.gas.massf[i]);
                }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) {
                F.vec[cqi.modes+i] += factor*(rR*uR*Rght.gas.u_modes[i]);
            }
        }
    } else  {
        // subsonic flow
        F.vec[cqi.mass] += factor*(( SRp*rL*uL - SLm*rR*uR + SLm*SRp*(rR-rL) )/(SRp-SLm));
        F.vec[cqi.xMom] += factor*(( SRp*(rL*uL*uL+pL) - SLm*(rR*uR*uR+pR) + SLm*SRp*(rR*uR-rL*uL) )/(SRp-SLm));
        F.vec[cqi.yMom] += factor*(( SRp*(rL*uL*vL) - SLm*(rR*uR*vR) + SLm*SRp*(rR*vR-rL*vL) )/(SRp-SLm));
        if (cqi.threeD) { F.vec[cqi.yMom] += factor*(( SRp*(rL*uL*wL) - SLm*(rR*uR*wR) + SLm*SRp*(rR*wR-rL*wL) )/(SRp-SLm)); }
        F.vec[cqi.totEnergy] += factor*(( SRp*(rL*uL*HL) - SLm*(rR*uR*HR) + SLm*SRp*(rR*HR-rL*HL) )/(SRp-SLm)); 
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) {
                F.vec[cqi.rhoturb+i] += factor*(( SRp*(rL*uL*Lft.turb[i]) - SLm*(rR*uR*Rght.turb[i]) + SLm*SRp*(rR*Rght.turb[i]-rL*Lft.turb[i]) )/(SRp-SLm));
            }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) {
                    F.vec[cqi.species+i] += factor*(( SRp*(rL*uL*Lft.gas.massf[i]) - SLm*(rR*uR*Rght.gas.massf[i]) + SLm*SRp*(rR*Rght.gas.massf[i]-rL*Lft.gas.massf[i]) )/(SRp-SLm));
                }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) {
                F.vec[cqi.modes+i] += factor*(( SRp*(rL*uL*Lft.gas.u_modes[i]) - SLm*(rR*uR*Rght.gas.u_modes[i]) + SLm*SRp*(rR*Rght.gas.u_modes[i]-rL*Lft.gas.u_modes[i]) )/(SRp-SLm));
            }
        }
    }
} // end hlle2()

@nogc
void roe(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0)
// Philip Roe's flux calculator with entropy fix.
//
// Particular implementation is based on the descriptions from
// J. Morrison (1990)
// Flux Difference Split Scheme for Turbulent Transport Equations, pg. 4.
// and
// Walters et al. (1992)
// Characteristic-Based Algorithms for Flows in Thermochemical Nonequilibrium, pg. 1307.
//
// with the entropy fix from
// Gnoffo et al. (2004)
// Computational Aerothermodynamic Simulation Issues on Unstructured Grids
{
    auto gmodel = myConfig.gmodel;
    // Unpack the flow-state vectors for either side of the interface.
    // Store in work vectors, those quantities that will be neede later.
    number rL = Lft.gas.rho;
    number TL = Lft.gas.T;
    number pL = Lft.gas.p;
    number pLrL = pL / rL;
    number uL = Lft.vel.x;
    number vL = Lft.vel.y;
    number wL = Lft.vel.z;
    number eL = gmodel.internal_energy(Lft.gas);
    number aL = Lft.gas.a;
    number keL = 0.5*(uL*uL + vL*vL + wL*wL);
    number HL = eL + pLrL + keL;
    number tkeL = 0.0;
    version(turbulence) {
        tkeL = myConfig.turb_model.turbulent_kinetic_energy(Lft);
        HL += tkeL;
    }
    //
    number rR = Rght.gas.rho;
    number TR = Rght.gas.T;
    number pR = Rght.gas.p;
    number pRrR = pR / rR;
    number uR = Rght.vel.x;
    number vR = Rght.vel.y;
    number wR = Rght.vel.z;
    number eR = gmodel.internal_energy(Rght.gas);
    number aR = Rght.gas.a;
    number keR = 0.5*(uR*uR + vR*vR + wR*wR);
    number HR = eR + pRrR + keR;
    number tkeR = 0.0;
    version(turbulence) {
        tkeR = myConfig.turb_model.turbulent_kinetic_energy(Rght);
        HR += tkeR;
    }
    // averaged gamma
    number gL = gmodel.gamma(Lft.gas);
    number gR = gmodel.gamma(Rght.gas);
    number ghat = (sqrt(rL)*gL+sqrt(rR)*gR) / (sqrt(rL) + sqrt(rR));
    // Roe averaged variables for the interface
    number rhat = sqrt(rL*rR);
    number That = (sqrt(rL)*TL+sqrt(rR)*TR) / (sqrt(rL) + sqrt(rR));
    number uhat = (sqrt(rL)*uL+sqrt(rR)*uR) / (sqrt(rL) + sqrt(rR));
    number vhat = (sqrt(rL)*vL+sqrt(rR)*vR) / (sqrt(rL) + sqrt(rR));
    number what = (sqrt(rL)*wL+sqrt(rR)*wR) / (sqrt(rL) + sqrt(rR));
    number Hhat = (sqrt(rL)*HL+sqrt(rR)*HR) / (sqrt(rL) + sqrt(rR));
    number tkehat = (sqrt(rL)*tkeL+sqrt(rR)*tkeR) / (sqrt(rL) + sqrt(rR));
    number kehat = 0.5*(uhat*uhat+vhat*vhat+what*what);
    number ahat2 = (ghat-1.0)*(Hhat-kehat-tkehat);
    number ahat = sqrt(ahat2);
    // Roe jump quantities for the interface
    number dr = rR-rL;
    number dp = pR-pL;
    number du = uR-uL;
    number dv = vR-vL;
    number dw = wR-wL;
    number dtke = 0.0;
    version(turbulence) {
        dtke = myConfig.turb_model.turbulent_kinetic_energy(Rght) - myConfig.turb_model.turbulent_kinetic_energy(Lft);
    }
    // the eigenvalues for the Jacobian
    number[3] lambda;
    lambda[0] = uhat; // this is the repeated eigenvalue
    lambda[1] = uhat+ahat;
    lambda[2] = uhat-ahat;
    // Apply entropy fix to eigenvalues (i.e. eigenvalue limiter)
    number phi = 0.5;
    number V = sqrt(uhat^^2+vhat^^2+what^^2);
    number lref = phi*(V+ahat);
    foreach (ref l; lambda) {
        if (fabs(l) >= 2*lref) { l = fabs(l); }
        else { l = (l*l)/(4*lref) + lref; }
    }
    // compute fluxes
    ConservedQuantities F = IFace.F;
    number FL; number FR;
    auto cqi = myConfig.cqi;
    // mass flux
    FL = rL*uL;
    FR = rR*uR;
    F.vec[cqi.mass] += factor*0.5*( FL + FR
                                    -( fabs(lambda[0])*(dr - dp/ahat2) )
                                    -( fabs(lambda[1])*((dp + rhat*ahat*du)/(2.0*ahat2)) )
                                    -( fabs(lambda[2])*((dp - rhat*ahat*du)/(2.0*ahat2)) )
                                    );
    // x-momentum flux;
    FL = pL+rL*uL*uL;
    FR = pR+rR*uR*uR;
    F.vec[cqi.xMom] += factor*0.5*( FL + FR
                                    -( fabs(lambda[0])*(dr - dp/ahat2)*uhat )
                                    -( fabs(lambda[1])*((dp + rhat*ahat*du)/(2.0*ahat2))*(uhat+ahat) )
                                    -( fabs(lambda[2])*((dp - rhat*ahat*du)/(2.0*ahat2))*(uhat-ahat) )
                                    );
    // y-momentum flux;
    FL = rL*uL*vL;
    FR = rR*uR*vR;
    F.vec[cqi.yMom] += factor*0.5*( FL + FR
                                    -( fabs(lambda[0])*((dr - dp/ahat2)*vhat + rhat*dv) )
                                    -( fabs(lambda[1])*((dp + rhat*ahat*du)/(2.0*ahat2))*vhat )
                                    -( fabs(lambda[2])*((dp - rhat*ahat*du)/(2.0*ahat2))*vhat )
                                    );
    // z-momentum flux;
    FL = rL*uL*wL;
    FR = rR*uR*wR;
    number zMom = factor*0.5*( FL + FR
                               -( fabs(lambda[0])*((dr - dp/ahat2)*what + rhat*dw) )
                               -( fabs(lambda[1])*((dp + rhat*ahat*du)/(2.0*ahat2))*what )
                               -( fabs(lambda[2])*((dp - rhat*ahat*du)/(2.0*ahat2))*what )
                               );
    if (cqi.threeD) { F.vec[cqi.zMom] += zMom; }
    // total energy flux
    number theta = 0.0;
    version(multi_species_gas) {
        // [TODO] PJ 2021-05-11 Is this appropriate for a single-species gas, now that Nick has adjusted things.
        uint nsp = (myConfig.sticky_electrons) ? myConfig.n_heavy : myConfig.n_species;
        if (cqi.n_species > 1) {
            foreach (i; 0 .. nsp) {
                number dmassf = Rght.gas.massf[i] - Lft.gas.massf[i];
                number eiL = gmodel.internal_energy(Lft.gas, i);
                number eiR = gmodel.internal_energy(Rght.gas, i);
                number eihat = (sqrt(rL)*eiL+sqrt(rR)*eiR) / (sqrt(rL) + sqrt(rR));
                number Ri = gmodel.gas_constant(IFace.fs.gas, i);
                // equation 33b from Walters et al. (1992)
                number psihat = Ri*That/(ghat-1.0) - eihat + kehat;
                theta += dmassf*psihat;
            }
        }
    }
    FL = rL*uL*HL;
    FR = rR*uR*HR;
    F.vec[cqi.totEnergy] += factor*0.5*( FL + FR
                                         -( fabs(lambda[0])*((dr - dp/ahat2)*(kehat + tkehat) + rhat*(vhat*dv+what*dw+dtke-theta)) )
                                         -( fabs(lambda[1])*((dp + rhat*ahat*du)/(2.0*ahat2))*(Hhat+uhat*ahat) )
                                         -( fabs(lambda[2])*((dp - rhat*ahat*du)/(2.0*ahat2))*(Hhat-uhat*ahat) )
                                         );
    version(turbulence) {
        foreach(i; 0 .. myConfig.turb_model.nturb) {
            number turbhat = (sqrt(rL)*Lft.turb[i]+sqrt(rR)*Rght.turb[i]) / (sqrt(rL) + sqrt(rR));
            number dturb = Rght.turb[i]-Lft.turb[i];
            FL = rL*uL*Lft.turb[i];
            FR = rR*uR*Rght.turb[i];
            F.vec[cqi.rhoturb+i] += factor*0.5*( FL + FR
                                                 -( fabs(lambda[0])*((dr - dp/ahat2)*turbhat + rhat*dturb) )
                                                 -( fabs(lambda[1])*((dp + rhat*ahat*du)/(2.0*ahat2))*turbhat )
                                                 -( fabs(lambda[2])*((dp - rhat*ahat*du)/(2.0*ahat2))*turbhat )
                                                 );
        }
    }
    version(multi_species_gas) {
        if (cqi.n_species > 1) {
            foreach (i; 0 .. nsp) {
                number massfhat = (sqrt(rL)*Lft.gas.massf[i]+sqrt(rR)*Rght.gas.massf[i]) / (sqrt(rL) + sqrt(rR));
                number dmassf = Rght.gas.massf[i] - Lft.gas.massf[i];
                FL = rL*uL*Lft.gas.massf[i];
                FR = rR*uR*Rght.gas.massf[i];
                F.vec[cqi.species+i] += factor*0.5*( FL + FR
                                                     -( fabs(lambda[0])*((dr - dp/ahat2)*massfhat + rhat*dmassf) )
                                                     -( fabs(lambda[1])*((dp + rhat*ahat*du)/(2.0*ahat2))*massfhat )
                                                     -( fabs(lambda[2])*((dp - rhat*ahat*du)/(2.0*ahat2))*massfhat )
                                                     );
            }
        }
    }
    version(multi_T_gas) {
        foreach (i; 0 .. myConfig.n_modes) {
            number enrghat = (sqrt(rL)*Lft.gas.u_modes[i]+sqrt(rR)*Rght.gas.u_modes[i]) / (sqrt(rL) + sqrt(rR));
            number denrg = Rght.gas.u_modes[i] - Lft.gas.u_modes[i];
            FL = rL*uL*Lft.gas.u_modes[i];
            FR = rR*uR*Rght.gas.u_modes[i];
            F.vec[cqi.modes+i] += factor*0.5*( FL + FR
                                               -( fabs(lambda[0])*((dr - dp/ahat2)*enrghat + rhat*denrg) )
                                               -( fabs(lambda[1])*((dp + rhat*ahat*du)/(2.0*ahat2))*enrghat )
                                               -( fabs(lambda[2])*((dp - rhat*ahat*du)/(2.0*ahat2))*enrghat )
                                               );
        }
    }
} // end roe()

@nogc
void ASF_242(ref FVInterface IFace, ref LocalConfig myConfig, number factor=1.0) {
    // Start by substracting interface velocities and transforming to local frame;
    // it is unlikely we will be using moving grids with this solver, but no harm in including this.
    auto gmodel = myConfig.gmodel;
    ConservedQuantities F = IFace.F;
    auto cqi = myConfig.cqi;
    // this stencil is using references to comply with @nogc
    // we need to convert back after we have finished with them
    // (this is very inefficient)
    FlowState[4] stencil = [IFace.left_cells[1].fs,  IFace.left_cells[0].fs,
                            IFace.right_cells[0].fs, IFace.right_cells[1].fs];
    foreach (cell; stencil) {
        cell.vel.x -= IFace.gvel.x;
        cell.vel.y -= IFace.gvel.y;
        cell.vel.z -= IFace.gvel.z;
        cell.vel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
    }
    // Define the v,w functions as prescribed by White et al. 2012 for the simple convective fluxes
    number[4][10] v, w;
    foreach (i, cell; stencil) {
        v[0][i] = cell.gas.rho;
        w[0][i] = cell.vel.x;
        v[1][i] = cell.vel.x * cell.gas.rho;
        w[1][i] = cell.vel.x;
        v[2][i] = cell.vel.y * cell.gas.rho;
        w[2][i] = cell.vel.x;
        v[3][i] = cell.vel.z * cell.gas.rho;
        w[3][i] = cell.vel.x;
        v[4][i] = gmodel.internal_energy(cell.gas) * cell.gas.rho;
        w[4][i] = cell.vel.x;
        v[5][i] = cell.vel.x * cell.vel.x * cell.gas.rho;
        w[5][i] = cell.vel.x;
        v[6][i] = cell.vel.y * cell.vel.y * cell.gas.rho;
        w[6][i] = cell.vel.x;
        v[7][i] = cell.vel.z * cell.vel.z * cell.gas.rho;
        w[7][i] = cell.vel.x;
        v[8][i] = cell.gas.p;
        w[8][i] = cell.vel.x;
        v[9][i] = cell.gas.p;
        w[9][i] = 1;
    }
    // convert back
    foreach (cell; stencil) {
        cell.vel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
        cell.vel.x += IFace.gvel.x;
        cell.vel.y += IFace.gvel.y;
        cell.vel.z += IFace.gvel.z;
    }
    // Prepare the conservative and product rule fluxes arrays
    number[10] f_c, f_e;
    // Calculate conservative and product rule fluxes
    foreach (i ; 0 .. 10) {
        f_c[i] = (1.0 / 12.0) * (-v[i][0] * w[i][0] + 7.0 * v[i][1] * w[i][1] + 7.0 * v[i][2] * w[i][2] - v[i][3] * w[i][3]);
        f_e[i] = (1.0 / 12.0) * (-v[i][0] * w[i][2] - v[i][2] * w[i][0] + 8 * v[i][1] * w[i][2] + 8 * v[i][2] * w[i][1] - v[i][1] * w[i][3] - v[i][3] * w[i][1]);
    }
    // Define the splitting values as per White et al, in the conservative skew-symmetric form of Honein and Moin.
    number alpha_mass = 1.0, alpha_mom = 0.5, alpha_ie = 0.5, alpha_ke = 0.0, alpha_p = 0.0;
    //
    // Calculate the final flux values of the simple quantities mass, momentum and energy
    number mass_flux = factor*(alpha_mass * f_c[0] + (1.0 - alpha_mass) * f_e[0]);
    F.vec[cqi.mass] += mass_flux;
    F.vec[cqi.xMom] += factor*(alpha_mom * f_c[1] + (1.0 - alpha_mom) * f_e[1]) + (alpha_p * f_c[9] + (1.0 - alpha_p) * f_e[9]);
    F.vec[cqi.yMom] += factor*(alpha_mom * f_c[2] + (1.0 - alpha_mom) * f_e[2]);
    if (cqi.threeD) { F.vec[cqi.zMom] += factor*(alpha_mom * f_c[3] + (1.0 - alpha_mom) * f_e[3]); }
    F.vec[cqi.totEnergy] += factor*(alpha_ie * f_c[4] + (1.0 - alpha_ie) * f_e[4] + (1.0 / 2.0) * (alpha_ke * f_c[5] + (1.0 - alpha_ke) * f_e[5] + alpha_ke * f_c[6] +
           (1.0 - alpha_ke) * f_e[6] + alpha_ke * f_c[7] + (1.0 - alpha_ke) * f_e[7]) + alpha_p * f_c[8] + (1.0 - alpha_p) * f_e[8]);
    //
    // remaining fluxes (copied from Roe flux)
    // Here we will base these extended properties based on the left and right cell average properties rather than some reconstructed values.
    if (mass_flux >= 0.0) {
        /* Wind is blowing from the left */
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] += mass_flux*IFace.left_cells[0].fs.turb[i]; }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] += mass_flux*IFace.left_cells[0].fs.gas.massf[i]; }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] += mass_flux*IFace.left_cells[0].fs.gas.u_modes[i]; }
        }
    } else {
        /* Wind is blowing from the right */
        version(turbulence) {
            foreach(i; 0 .. myConfig.turb_model.nturb) { F.vec[cqi.rhoturb+i] += mass_flux*IFace.right_cells[0].fs.turb[i]; }
        }
        version(multi_species_gas) {
            if (cqi.n_species > 1) {
                foreach (i; 0 .. cqi.n_species) { F.vec[cqi.species+i] += mass_flux*IFace.right_cells[0].fs.gas.massf[i]; }
            }
        }
        version(multi_T_gas) {
            foreach (i; 0 .. cqi.n_modes) { F.vec[cqi.modes+i] += mass_flux*IFace.right_cells[0].fs.gas.u_modes[i]; }
        }
    }

    // If we're doing pure high-order flux, we bypass the normal convective flux program path so need to transform the fluxes to the global frame here

    if (factor == 1.0) {
        if (cqi.threeD) {
            F.vec[cqi.zMom] += IFace.gvel.z * F.vec[cqi.mass];
            transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], F.vec[cqi.zMom], IFace.n, IFace.t1, IFace.t2);
        } else {
            number zDummy = to!number(0.0);
            transform_to_global_frame(F.vec[cqi.xMom], F.vec[cqi.yMom], zDummy, IFace.n, IFace.t1, IFace.t2);
        }
    }
} // end ASF_242()

@nogc
void adaptive_ausmdv_asf(in FlowState Lft, in FlowState Rght, ref FVInterface IFace, ref LocalConfig myConfig)
// This adaptive flux calculator uses the AUSMDV flux calculator
// near shocks and ASF_242 away from shocks.
//
// The actual work is passed off to the original flux calculation functions.
{
    number alpha = IFace.fs.S;
    if (alpha > 0.0) {
        ausmdv(Lft, Rght, IFace, myConfig, alpha);
    }
    if (alpha < 1.0) {
        ASF_242(IFace, myConfig, 1.0-alpha);
    }
    return;
}
