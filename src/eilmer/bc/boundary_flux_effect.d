/**
 * boundary_flux_effect.d
 *
 * Authors: RG and PJ
 * Date: 2015-05-07
 * Author: KD added ConstFlux
 * Date: 2015-11-10
 **/

module bc.boundary_flux_effect;

import std.stdio;
import std.json;
import std.string;
import std.conv;
import std.math;
import nm.complex;
import nm.number;
import nm.bbla;
import nm.brent; 
import nm.bracketing;

import geom;
import json_helper;
import globalconfig;
import globaldata;
import fluidblock;
import sfluidblock;
import fvcore;
import fvcell;
import fvinterface;
import solidfvcell;
import solidfvinterface;
import gas_solid_interface;
import flowstate;
import gas;
import bc;
import flowgradients;
import mass_diffusion;
//import nm.ridder;
//import nm.bracketing;

BoundaryFluxEffect make_BFE_from_json(JSONValue jsonData, int blk_id, int boundary)
{
    string bfeType = jsonData["type"].str;
    BoundaryFluxEffect newBFE;
    auto gmodel = GlobalConfig.gmodel_master;
    
    switch ( bfeType ) {
    case "const_flux":
        auto flowstate = new FlowState(jsonData["flowstate"], gmodel);
        newBFE = new BFE_ConstFlux(blk_id, boundary, flowstate);
        break;
    case "simple_outflow_flux":
        newBFE = new BFE_SimpleOutflowFlux(blk_id, boundary);
        break;
    case "user_defined":
        string fname = getJSONstring(jsonData, "filename", "none");
        string funcName = getJSONstring(jsonData, "function_name", "none");
        newBFE = new BFE_UserDefined(blk_id, boundary, fname, funcName);
        break;
    case "energy_flux_from_adjacent_solid":
        int otherBlock = getJSONint(jsonData, "other_block", -1);
        string otherFaceName = getJSONstring(jsonData, "other_face", "none");
        int neighbourOrientation = getJSONint(jsonData, "neighbour_orientation", 0);
        newBFE = new BFE_EnergyFluxFromAdjacentSolid(blk_id, boundary,
                                                     otherBlock, face_index(otherFaceName),
                                                     neighbourOrientation);
        break;
        case "energy_balance_thermionic":
        double emissivity = getJSONdouble(jsonData, "emissivity", 0.0);
        double Ar = getJSONdouble(jsonData, "Ar", 0.0);
        double phi = getJSONdouble(jsonData, "phi", 0.0);
        int ThermionicEmissionActive = getJSONint(jsonData, "ThermionicEmissionActive", 1);
        int Twall_iterations = getJSONint(jsonData, "Twall_iterations", 200);
        int Twall_subiterations = getJSONint(jsonData, "Twall_subiterations", 20);
        newBFE = new BFE_EnergyBalanceThermionic(blk_id, boundary, emissivity, Ar, phi,
                                 ThermionicEmissionActive, Twall_iterations, Twall_subiterations);
        break;
    case "update_energy_wall_normal_velocity":
        newBFE = new BFE_UpdateEnergyWallNormalVelocity(blk_id, boundary);
        break;
    default:
        string errMsg = format("ERROR: The BoundaryFluxEffect type: '%s' is unknown.", bfeType);
        throw new Error(errMsg);
    }
    
    return newBFE;
}

class BoundaryFluxEffect {
public:
    FluidBlock blk;
    int which_boundary;
    string desc;
    
    this(int id, int boundary, string description)
    {
        blk = globalFluidBlocks[id];
        which_boundary = boundary;
        desc = description;
    }
    void post_bc_construction() {}
    override string toString() const
    {
        return "BoundaryFluxEffect()";
    }
    void apply(double t, int gtl, int ftl)
    {
        final switch (blk.grid_type) {
        case Grid_t.unstructured_grid: 
            apply_unstructured_grid(t, gtl, ftl);
            break;
        case Grid_t.structured_grid:
            apply_structured_grid(t, gtl, ftl);
        }
    }
    abstract void apply_unstructured_grid(double t, int gtl, int ftl);
    abstract void apply_structured_grid(double t, int gtl, int ftl);
} // end class BoundaryFluxEffect()

// NOTE: This GAS DOMAIN boundary effect has a large
//       and important side-effect:
//       IT ALSO SETS THE FLUX IN THE ADJACENT SOLID DOMAIN
//       AT THE TIME IT IS CALLED.

class BFE_EnergyFluxFromAdjacentSolid : BoundaryFluxEffect {
public:
    int neighbourSolidBlk;
    int neighbourSolidFace;
    int neighbourOrientation;

    this(int id, int boundary,
         int otherBlock, int otherFace, int orient)
    {
        super(id, boundary, "EnergyFluxFromAdjacentSolid");
        neighbourSolidBlk = otherBlock;
        neighbourSolidFace = otherFace;
        neighbourOrientation = orient;
    }

    override string toString() const 
    {
        return "BFE_EnergyFluxFromAdjacentSolid()";
    }
    override void apply_unstructured_grid(double t, int gtl, int ftl)
    {
        throw new Error("BFE_EnergyFluxFromAdjacentSolid.apply_unstructured_grid() not yet implemented");
    }

    override void apply_structured_grid(double t, int gtl, int ftl)
    {
        if (blk.myConfig.solid_has_isotropic_properties) {
            computeFluxesAndTemperatures(ftl, _gasCells, _gasIFaces, _solidCells, _solidIFaces);
        }
        else {
            computeFluxesAndTemperatures2(ftl, _gasCells, _gasIFaces, _solidCells, _solidIFaces,
                                         _T, _B, _A, _pivot);
        }
    }

private:
    // Some private working arrays.
    // We'll pack data into these can pass out
    // to a routine that can compute the flux and
    // temperatures that balance at the interface.
    FVCell[] _gasCells;
    FVInterface[] _gasIFaces;
    SolidFVCell[] _solidCells;
    SolidFVInterface[] _solidIFaces;
    number[] _T;
    number[] _B;
    Matrix!number _A;
    int[] _pivot;

public:
    void initSolidCellsAndIFaces()
    {
        size_t i, j, k;
        auto blk = solidBlocks[neighbourSolidBlk];
        switch ( neighbourSolidFace ) {
        case Face.south:
            j = blk.jmin;
            for (k = blk.kmin; k <= blk.kmax; ++k) {
                for (i = blk.imin; i <= blk.imax; ++i) {
                    _solidCells ~= blk.getCell(i, j, k);
                    _solidIFaces ~= _solidCells[$-1].iface[Face.south];
                }
            }
            if (!blk.myConfig.solid_has_isotropic_properties) {
                // We'll need to initialise working space for the
                // linear system solve.
                auto n = _solidIFaces.length;
                _T.length = n;
                _B.length = n;
                _A = new Matrix!number(n);
                _pivot.length = n;
            }
            break;
        default:
            throw new Error("initSolidCellsAndIFaces() only implemented for SOUTH face.");
        }
    }

    void initGasCellsAndIFaces()
    {
        size_t i, j, k;
        auto blk = cast(SFluidBlock) this.blk;
        assert(blk !is null, "Oops, this should be an SFluidBlock object.");
        switch ( which_boundary ) {
        case Face.north:
            j = blk.jmax;
            for (k = blk.kmin; k <= blk.kmax; ++k) {
                for (i = blk.imin; i <= blk.imax; ++i) {
                    _gasCells ~= blk.get_cell(i, j, k);
                    _gasIFaces ~= _gasCells[$-1].iface[Face.north];
                }
            }
            break;
        default:
            throw new Error("initGasCellsAndIFaces() only implemented for NORTH gas face.");
        }
    }
}

class BFE_ConstFlux : BoundaryFluxEffect {
public:
    FlowState fstate;

private:
    number[] _massf;
    number _e, _rho, _p, _u, _v;
    FlowState _fstate;
    int _nsp;
   
public:  
    this(int id, int boundary, in FlowState fstate)
    {
        /+ We only need to gather the freestream values once at
         + the start of simulation since we are interested in
         + applying a constant flux as the incoming boundary
         + condition.
        +/
        //auto gmodel = blk.myConfig.gmodel;
        auto gmodel = GlobalConfig.gmodel_master;
        super(id, boundary, "Const_Flux");
        _u = fstate.vel.x;
        _v = fstate.vel.y;
        // [TODO]: Kyle, think about z component.
        _p = fstate.gas.p;
        _rho = fstate.gas.rho;
        _e = gmodel.internal_energy(fstate.gas);
        _nsp = gmodel.n_species;
        _massf.length = _nsp;
        for (int _isp=0; _isp < _nsp; _isp++) {
            _massf[_isp] = fstate.gas.massf[_isp];
        }
        this.fstate = fstate.dup();
    }

    override string toString() const 
    {
        return "BFE_ConstFlux";
    }

    override void apply_unstructured_grid(double t, int gtl, int ftl)
    {
        throw new Error("BFE_ConstFlux.apply_unstructured_grid() not yet implemented");
    }
    
    override void apply_structured_grid(double t, int gtl, int ftl)
    {
        FVInterface IFace;
        size_t i, j, k;
        number _u_rel, _v_rel;
        auto blk = cast(SFluidBlock) this.blk;
        assert(blk !is null, "Oops, this should be an SFluidBlock object.");

        switch(which_boundary){
        case Face.west:
            i = blk.imin;
            for (k = blk.kmin; k <= blk.kmax; ++k) {
                for (j = blk.jmin; j <= blk.jmax; ++j) {
                    // Flux equations
                    IFace = blk.get_cell(i,j,k).iface[Face.west];
                    // for a moving grid we need vel relative to the interface
                    _u_rel = _u - IFace.gvel.x;
                    _v_rel = _v - IFace.gvel.y;
                    IFace.F.mass = _rho * ( _u_rel*IFace.n.x + _v_rel*IFace.n.y );
                    /++ when the boundary is moving we use the relative velocity
                      + between the fluid and the boundary interface to determine
                      + the amount of mass flux across the cell face (above). 
                      + Alternatively momentum is a fluid property hence we use the 
                      + fluid velocity in determining the momentum flux -- this is 
                      + akin to saying we know how much mass flux is crossing 
                      + the cell face of which this mass has a momentum dependant 
                      + on its velocity. Since we we want this momentum flux in global 
                      + coordinates there is no need to rotate the velocity.
                      ++/
                    IFace.F.momentum.refx = _p * IFace.n.x + _u*IFace.F.mass;
                    IFace.F.momentum.refy = _p * IFace.n.y + _v*IFace.F.mass;
                    IFace.F.momentum.refz = 0.0;
                    // [TODO]: Kyle, think about z component.
                    IFace.F.total_energy = IFace.F.mass * (_e + 0.5*(_u*_u+_v*_v)) + _p*(_u*IFace.n.x+_v*IFace.n.y);
                    for ( int _isp = 0; _isp < _nsp; _isp++ ){
                        IFace.F.massf[_isp] = IFace.F.mass * _massf[_isp];
                    }
                    // [TODO]: Kyle, separate energy modes for multi-species simulations.
                } // end j loop
            } // end k loop
            break;
        default:
            throw new Error("Const_Flux only implemented for WEST gas face.");
        }
    }
}

class BFE_SimpleOutflowFlux : BoundaryFluxEffect {
public:  
    this(int id, int boundary)
    {
        auto gmodel = blk.myConfig.gmodel;
        super(id, boundary, "Simple_Outflow_Flux");
    }

    override string toString() const 
    {
        return "BFE_SimpleOutflowFlux";
    }

    override void apply_unstructured_grid(double t, int gtl, int ftl)
    {
        throw new Error("BFE_SimpleOutflowFlux.apply_unstructured_grid() not yet implemented");
    }
    
    override void apply_structured_grid(double t, int gtl, int ftl)
    {
        FVInterface IFace;
        size_t i, j, k;
        number _u_rel, _v_rel;
        auto blk = cast(SFluidBlock) this.blk;
        assert(blk !is null, "Oops, this should be an SFluidBlock object.");

        switch(which_boundary){
        case Face.west:
            i = blk.imin;
            for (k = blk.kmin; k <= blk.kmax; ++k) {
                for (j = blk.jmin; j <= blk.jmax; ++j) {
                    /+ PJ [FIX-ME] 2018-10-23
                    // Flux equations
                    IFace = blk.get_cell(i,j,k).iface[Face.west];
                    // for a moving grid we need vel relative to the interface
                    _u_rel = _u - IFace.gvel.x;
                    _v_rel = _v - IFace.gvel.y;
                    IFace.F.mass = _rho * ( _u_rel*IFace.n.x + _v_rel*IFace.n.y );
                    /++ when the boundary is moving we use the relative velocity
                      + between the fluid and the boundary interface to determine
                      + the amount of mass flux across the cell face (above). 
                      + Alternatively momentum is a fluid property hence we use the 
                      + fluid velocity in determining the momentum flux -- this is 
                      + akin to saying we know how much mass flux is crossing 
                      + the cell face of which this mass has a momentum dependant 
                      + on its velocity. Since we we want this momentum flux in global 
                      + coordinates there is no need to rotate the velocity.
                      ++/
                    IFace.F.momentum.refx = _p * IFace.n.x + _u*IFace.F.mass;
                    IFace.F.momentum.refy = _p * IFace.n.y + _v*IFace.F.mass;
                    IFace.F.momentum.refz = 0.0;
                    // [TODO]: Kyle, think about z component.
                    IFace.F.total_energy = IFace.F.mass * (_e + 0.5*(_u*_u+_v*_v)) + _p*(_u*IFace.n.x+_v*IFace.n.y);
                    for ( int _isp = 0; _isp < _nsp; _isp++ ){
                        IFace.F.massf[_isp] = IFace.F.mass * _massf[_isp];
                    }
                    // [TODO]: Kyle, separate energy modes for multi-species simulations.
                    +/
                } // end j loop
            } // end k loop
            break;
        default:
            throw new Error("SimpleOutflowFlux only implemented for WEST gas face (not even that [FIX-ME].");
        }
    }
}

class BFE_EnergyBalanceThermionic : BoundaryFluxEffect {
public:
    // Function inputs from Eilmer4 .lua simulation input
    double emissivity;  // Input emissivity, 0<e<=1.0. Assumed black body radiation out from wall
    double Ar;          // Richardson constant, material-dependent
    double phi;         // Work function, material dependent. Input units in eV, 
                        // this gets converted to Joules by multiplying by Elementary charge, Qe
    int ThermionicEmissionActive;  // Whether or not Thermionic Emission is active. Default is 'on'

    // Solver iteration counts
    int Twall_iterations;  // Iterations for primary Twall calculations. Default = 200
    int Twall_subiterations;  // Iterations for newton method when ThermionicEmissionActive==1. Default = 20

    // Constants used in analysis
    double SB_sigma = 5.670373e-8;  // Stefan-Boltzmann constant.   Units: W/(m^2 K^4)
    double kb = 1.38064852e-23;     // Boltzmann constant.          Units: (m^2 kg)/(s^2 K^1)
    double Qe = 1.60217662e-19;     // Elementary charge.           Units: C
 
    this(int id, int boundary, double emissivity, double Ar, double phi, int ThermionicEmissionActive,
        int Twall_iterations, int Twall_subiterations)
    {
        super(id, boundary, "EnergyBalanceThermionic");
        this.emissivity = emissivity;
        this.Ar = Ar;
        this.phi = phi*Qe;  // Convert phi from input 'eV' to 'J'
        this.ThermionicEmissionActive = ThermionicEmissionActive;
        this.Twall_iterations = Twall_iterations;
        this.Twall_subiterations = Twall_subiterations;
    }

    override string toString() const 
    {
        return "BFE_EnergyBalanceThermionic(ThermionicEmissionActive=" ~
            to!string(ThermionicEmissionActive) ~ 
            ", Work Function =" ~ to!string(phi/Qe) ~
            "eV , emissivity=" ~ to!string(emissivity) ~ 
            ", Richardson Constant=" ~ to!string(Ar) ~
            ")";
    }

    override void apply_unstructured_grid(double t, int gtl, int ftl)
    {
        throw new Error("BFE_EnergyBalanceThermionic.apply_unstructured_grid() not yet implemented");
    }
    
    override void apply_structured_grid(double t, int gtl, int ftl)
    {
        auto blk = cast(SFluidBlock) this.blk;
        assert(blk !is null, "Oops, this should be an SFluidBlock object.");
        if (t < blk.myConfig.thermionic_emission_bc_time_delay){
            return;
        }
        if ( emissivity <= 0.0 || emissivity > 1.0 ) {
            // Check if emissivity value is valid
            throw new Error("emissivity should be 0.0<e<=1.0\n");
        } else if ( Ar == 0.0){
            throw new Error("Ar should be set!\n");                 
        } else if ( phi == 0.0){
            throw new Error("phi should be set!\n");
        } else if (blk.myConfig.turbulence_model != TurbulenceModel.none) {
            throw new Error("WallBC_ThermionicEmission only implemented for laminar flow\n");
        } else {

            FVInterface IFace;
            size_t i, j, k;
            FVCell cell;

            final switch (which_boundary) {
            case Face.north:
                j = blk.jmax;
                for (k = blk.kmin; k <= blk.kmax; ++k) {
                    for (i = blk.imin; i <= blk.imax; ++i) {
                        // Set cell/face properties
                        cell = blk.get_cell(i,j,k);
                        IFace = cell.iface[Face.east];
                        double dn = distance_between(cell.pos[0], IFace.pos);
                        // Flux equations
                        // Energy balance by solving for the wall surface temperature
                        IFace.F.total_energy = solve_for_wall_temperature_and_energy_flux(cell, IFace, dn);
                    } // end i loop
                } // end for k
                break;
            case Face.east:
                i = blk.imax;
                for (k = blk.kmin; k <= blk.kmax; ++k) {
                    for (j = blk.jmin; j <= blk.jmax; ++j) {
                        // Set cell/face properties
                        cell = blk.get_cell(i,j,k);
                        IFace = cell.iface[Face.east];
                        double dn = distance_between(cell.pos[0], IFace.pos);
                        // Flux equations
                        // Energy balance by solving for the wall surface temperature
                        IFace.F.total_energy = solve_for_wall_temperature_and_energy_flux(cell, IFace, dn);
                    } // end j loop
                } // end for k
                break;
            case Face.south:
                j = blk.jmin;
                for (k = blk.kmin; k <= blk.kmax; ++k) {
                    for (i = blk.imin; i <= blk.imax; ++i) {
                        // Set cell/face properties
                        cell = blk.get_cell(i,j,k);
                        IFace = cell.iface[Face.south];
                        double dn = distance_between(cell.pos[0], IFace.pos);
                        // Negative for SOUTH face
                        IFace.F.total_energy = -1*solve_for_wall_temperature_and_energy_flux(cell, IFace, dn);
                    } // end i loop
                } // end for k
                break;
            case Face.west:
                i = blk.imin;
                for (k = blk.kmin; k <= blk.kmax; ++k) {
                    for (j = blk.jmin; j <= blk.jmax; ++j) {
                        // Set cell/face properties
                        cell = blk.get_cell(i,j,k);
                        IFace = cell.iface[Face.south];
                        double dn = distance_between(cell.pos[0], IFace.pos);
                        // Negative for WEST face
                        IFace.F.total_energy = -1*solve_for_wall_temperature_and_energy_flux(cell, IFace, dn);
                    } // end j loop
                } // end for k
                break;
            case Face.top:
                k = blk.kmax;
                for (i = blk.imin; i <= blk.imax; ++i) {
                    for (j = blk.jmin; j <= blk.jmax; ++j) {
                        // Set cell/face properties
                        cell = blk.get_cell(i,j,k);
                        IFace = cell.iface[Face.east];
                        double dn = distance_between(cell.pos[0], IFace.pos);
                        // Flux equations
                        // Energy balance by solving for the wall surface temperature
                        IFace.F.total_energy = solve_for_wall_temperature_and_energy_flux(cell, IFace, dn);
                    } // end j loop
                } // end for i
                break;
            case Face.bottom:
                k = blk.kmin;
                for (i = blk.imin; i <= blk.imax; ++i) {
                    for (j = blk.jmin; j <= blk.jmax; ++j) {
                        // Set cell/face properties
                        cell = blk.get_cell(i,j,k);
                        IFace = cell.iface[Face.south];
                        double dn = distance_between(cell.pos[0], IFace.pos);
                        // Negative for BOTTOM face
                        IFace.F.total_energy = -1*solve_for_wall_temperature_and_energy_flux(cell, IFace, dn);
                    } // end j loop
                } // end for i
                break;
            } // end switch which_boundary
        } // end apply_structured_grid()
    }


    double solve_for_wall_temperature_and_energy_flux(const FVCell cell, FVInterface IFace, double dn)
    // Iteratively converge on wall temp
    {
        double TOL = 1.0e-3;
        number Tlow = 300.0;
        number Thigh = 5000.0;

        auto gmodel = blk.myConfig.gmodel; 

        // IFace orientation
        number nx = IFace.n.x; number ny = IFace.n.y; number nz = IFace.n.z;
        // IFace properties.
        FlowGradients grad = IFace.grad;
        double viscous_factor = blk.myConfig.viscous_factor;


        number zeroFun(number T)
        {
            IFace.fs.gas.T = T;
            IFace.fs.gas.p = cell.fs.gas.p;
            gmodel.update_thermo_from_pT(IFace.fs.gas);
            gmodel.update_trans_coeffs(IFace.fs.gas);

            number dT = (cell.fs.gas.T - IFace.fs.gas.T); 
            number k_eff = viscous_factor * (IFace.fs.gas.k + IFace.fs.k_t);
            number dTdn = dT / dn;
            number q_total = k_eff * dTdn;
            if (blk.myConfig.turbulence_model != TurbulenceModel.none ||
                blk.myConfig.mass_diffusion_model != MassDiffusionModel.none) {
                q_total -= IFace.q_diffusion;
            }

            number f_rad = emissivity*SB_sigma*T*T*T*T;
            number f_thermionic = to!number(0.0);
            if (ThermionicEmissionActive == 1) {
                f_thermionic = Ar*T*T*exp(-phi/(kb*T))/Qe*(phi + 2*kb*T);
            }

            return f_rad + f_thermionic - q_total;
        }

        if (bracket!(zeroFun,number)(Tlow, Thigh) == -1) {
            string msg = "The 'bracket' function failed to find bracketing temperature values in thermionic emission boundary condition.\n";
            throw new Exception(msg);
        }

        number Twall = -1.0;
        try {
            Twall = solve!(zeroFun,number)(Tlow, Thigh, TOL);
        }
        catch (Exception e) {
            string msg = "There was a problem iterating to find temperature in ETC boundary condition.\n";
            throw new Exception(msg);
        }

        // If successful, set temperature, flux and gradients
        IFace.fs.gas.T = Twall;
        IFace.fs.gas.p = cell.fs.gas.p;
        gmodel.update_thermo_from_pT(IFace.fs.gas);
        gmodel.update_trans_coeffs(IFace.fs.gas);
        number dT = (cell.fs.gas.T - IFace.fs.gas.T); 
        number k_eff = viscous_factor * (IFace.fs.gas.k + IFace.fs.k_t);
        number dTdn = dT / dn;
        number q_total = k_eff * dTdn;
        if (blk.myConfig.turbulence_model != TurbulenceModel.none ||
            blk.myConfig.mass_diffusion_model != MassDiffusionModel.none) {
            q_total -= IFace.q_diffusion;
        }
        grad.T[0] = dTdn * nx;
        grad.T[1] = dTdn * ny;
        grad.T[2] = dTdn * nz;

        return q_total.re;

    } // end solve_for_wall_temperature_and_energy_flux()

} // end class BIE_EnergyBalanceThermionic


/**
 * BFE_UpdateEnergyWallNormalVelocity is a boundary Flux Effect 
 * that can be called for moving walls that have a wall normal 
 * velocity component.
 * It operates by incrementing total_energy to correct for work 
 * done on fluid by moving wall:
 * total_energy += pressure * Wall_normal_velocity
 *
*/
class BFE_UpdateEnergyWallNormalVelocity : BoundaryFluxEffect {
public:
    this(int id, int boundary)
    {
        // Don't need to do anything specific
        super(id, boundary, "UpdateEnergyWallNormalVelocity");
    }

    override string toString() const 
    {
        return "BFE_UpdateEnergyWallNormalVelocity";
    }

    override void apply_unstructured_grid(double t, int gtl, int ftl)
    {
        throw new Error("BFE_UpdateEnergyWallNormalVelocity.apply_unstructured_grid() not yet implemented");
    }
    
    override void apply_structured_grid(double t, int gtl, int ftl)
    {
        FVInterface IFace;
        size_t i, j, k;
        Vector3 nx,ny,nz;
        nx.set(1,0,0); ny.set(0,1,0); nz.set(0,0,1);
        auto blk = cast(SFluidBlock) this.blk;
        assert(blk !is null, "Oops, this should be an SFluidBlock object.");

        switch(which_boundary){
        case Face.west:
            i = blk.imin;
            for (k = blk.kmin; k <= blk.kmax; ++k) {
                for (j = blk.jmin; j <= blk.jmax; ++j) {
                    // get interface
                    IFace = blk.get_cell(i,j,k).iface[Face.west];
                    //writeln("Before: Total energy:",IFace.F.total_energy, "X_mom", IFace.F.momentum.refx, "mass", IFace.F.mass);
                    
                    // set correct energy and momentum flux
                    IFace.F.total_energy = IFace.fs.gas.p * dot(IFace.n, IFace.gvel);
                    IFace.F.momentum.refx = IFace.fs.gas.p * dot(IFace.n, nx);
                    IFace.F.momentum.refy = IFace.fs.gas.p * dot(IFace.n, ny);
                    IFace.F.momentum.refz = IFace.fs.gas.p * dot(IFace.n, nz);
                    IFace.F.mass = 0.;
                    //writeln("Pressure", IFace.fs.gas.p, "IFace.gvel",IFace.gvel);
                    //writeln("After: Total energy:",IFace.F.total_energy, "X_mom", IFace.F.momentum.refx, "mass", IFace.F.mass);

                } // end j loop
            } // end k loop
            break;
        case Face.east:
            i = blk.imax;
            for (k = blk.kmin; k <= blk.kmax; ++k) {
                for (j = blk.jmin; j <= blk.jmax; ++j) {
                    // get interface
                    IFace = blk.get_cell(i,j,k).iface[Face.east];
                    //writeln("Before: Total energy:",IFace.F.total_energy, "X_mom", IFace.F.momentum.refx, "mass", IFace.F.mass);

                    // set correct energy and momentum flux
                    IFace.F.total_energy =  IFace.fs.gas.p * dot(IFace.n, IFace.gvel);
                    IFace.F.momentum.refx = IFace.fs.gas.p * dot(IFace.n, nx);
                    IFace.F.momentum.refy = IFace.fs.gas.p * dot(IFace.n, ny);
                    IFace.F.momentum.refz = IFace.fs.gas.p * dot(IFace.n, nz);
                    IFace.F.mass = 0.;
                    //writeln("Pressure", IFace.fs.gas.p, "IFace.gvel",IFace.gvel);
                    //writeln("After: Total energy:",IFace.F.total_energy, "X_mom", IFace.F.momentum.refx, "mass", IFace.F.mass);
                } // end j loop
            } // end k loop
            break;
        case Face.south:
            j = blk.jmin;
            for (k = blk.kmin; k <= blk.kmax; ++k) {
                for (i = blk.imin; i <= blk.imax; ++i) {
                    // get interface
                    IFace = blk.get_cell(i,j,k).iface[Face.south];
                    // set correct energy and momentum flux
                    IFace.F.total_energy =  IFace.fs.gas.p * dot(IFace.n, IFace.gvel);
                    IFace.F.momentum.refx = IFace.fs.gas.p * dot(IFace.n, nx);
                    IFace.F.momentum.refy = IFace.fs.gas.p * dot(IFace.n, ny);
                    IFace.F.momentum.refz = IFace.fs.gas.p * dot(IFace.n, nz);
                    IFace.F.mass = 0.;
                } // end i loop
            } // end k loop
            break;
        case Face.north:
            j = blk.jmax;
            for (k = blk.kmin; k <= blk.kmax; ++k) {
                for (i = blk.imin; i <= blk.imax; ++i) {
                    // get interface
                    IFace = blk.get_cell(i,j,k).iface[Face.north];
                    // set correct energy and momentum flux
                    IFace.F.total_energy =  IFace.fs.gas.p * dot(IFace.n, IFace.gvel);
                    IFace.F.momentum.refx = IFace.fs.gas.p * dot(IFace.n, nx);
                    IFace.F.momentum.refy = IFace.fs.gas.p * dot(IFace.n, ny);
                    IFace.F.momentum.refz = IFace.fs.gas.p * dot(IFace.n, nz);
                    IFace.F.mass = 0.;
                } // end i loop
            } // end k loop
            break;
        case Face.bottom:
            k = blk.kmin;
            for (j = blk.jmin; j <= blk.jmax; ++j) {
                for (i = blk.imin; i <= blk.imax; ++j) {
                    // get interface
                    IFace = blk.get_cell(i,j,k).iface[Face.bottom];
                    // set correct energy and momentum flux
                    IFace.F.total_energy =  IFace.fs.gas.p * dot(IFace.n, IFace.gvel);
                    IFace.F.momentum.refx = IFace.fs.gas.p * dot(IFace.n, nx);
                    IFace.F.momentum.refy = IFace.fs.gas.p * dot(IFace.n, ny);
                    IFace.F.momentum.refz = IFace.fs.gas.p * dot(IFace.n, nz);
                    IFace.F.mass = 0.;
                } // end i loop
            } // end j loop
            break;
        case Face.top:
            k = blk.kmax;
            for (j = blk.jmin; j <= blk.jmax; ++j) {
                for (i = blk.imin; i <= blk.imax; ++j) {
                    // get interface
                    IFace = blk.get_cell(i,j,k).iface[Face.top];
                    // set correct energy and momentum flux
                    IFace.F.total_energy =  IFace.fs.gas.p * dot(IFace.n, IFace.gvel);
                    IFace.F.momentum.refx = IFace.fs.gas.p * dot(IFace.n, nx);
                    IFace.F.momentum.refy = IFace.fs.gas.p * dot(IFace.n, ny);
                    IFace.F.momentum.refz = IFace.fs.gas.p * dot(IFace.n, nz);
                    IFace.F.mass = 0.;
                } // end i loop
            } // end j loop
            break;
        default:
            throw new Error("Const_Flux only implemented for EAST & WEST gas face.");
        }
    }
} // end BFE_UpdateEnergyWallNormalVelocity

