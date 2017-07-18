db.H = {}
db.H.atomicConstituents = {H=1,}
db.H.charge = 0
db.H.M = {
   value = 0.00100794,
   units = 'kg/mol',
   description = 'molecular mass',
   reference = 'CEA2::thermo.inp'
}
db.H.gamma = {
   value = 1.66666667,
   units = 'non-dimensional',
   description = '(ideal) ratio of specific heats at room temperature',
   reference = 'monatomic gas'
}
db.H.sigma = {
   value = 2.050,
   units = 'Angstrom',
   description = 'Lennard-Jones potential distance',
   reference = 'GRI-Mech 3.0 transport file.'
}
db.H.epsilon = {
   value = 145.000,
   units = 'K',
   description = 'Lennard-Jones potential well depth.',
   reference = 'GRI-Mech 3.0 transport file.'
}
db.H.ceaThermoCoeffs = {
   nsegments = 3,
   segment0 = {
      T_lower = 200.0,
      T_upper = 1000.0,
      coeffs = {
          0.000000000e+00,
          0.000000000e+00,
          2.500000000e+00,
          0.000000000e+00,
          0.000000000e+00,
          0.000000000e+00,
          0.000000000e+00,
          2.547370801e+04,
         -4.466828530e-01,
      }
   },
   segment1 = {
      T_lower = 1000.0,
      T_upper = 6000.0,
      coeffs = {
          6.078774250e+01,
         -1.819354417e-01,
          2.500211817e+00,
         -1.226512864e-07,
          3.732876330e-11,
         -5.687744560e-15,
          3.410210197e-19,
          2.547486398e+04,
         -4.481917770e-01,
      }
   },
   segment2 = {
      T_lower = 6000.0,
      T_upper = 20000.0,
      coeffs = {
          2.173757694e+08,
         -1.312035403e+05,
          3.399174200e+01,
         -3.813999680e-03,
          2.432854837e-07,
         -7.694275540e-12,
          9.644105630e-17,
          1.067638086e+06,
         -2.742301051e+02,
      }
   },
}
db.H.ceaViscosity = {
   nsegments = 2,
   segment0 = {
      T_lower = 1000.0,
      T_upper = 5000.0,
      A =  7.4226149e-01,
      B = -4.0132865e+02,
      C =  1.8554165e+05,
      D =  4.6741844e-02
   },
   segment1 = {
      T_lower = 5000.0,
      T_upper = 15000.0,
      A =  8.7486623e-01,
      B = -2.5022902e+03,
      C =  7.0955048e+06,
      D = -9.3888455e-01
   },
}
db.H.ceaThermCond = {
   nsegments = 2,
   segment0 = {
      T_lower = 1000.0,
      T_upper = 5000.0,
      A =  7.4166119e-01,
      B = -4.0487203e+02,
      C =  1.8775642e+05,
      D =  3.4843121e+00
   },
   segment1 = {
      T_lower = 5000.0,
      T_upper = 15000.0,
      A =  8.7447639e-01,
      B = -2.5089452e+03,
      C =  7.1081294e+06,
      D =  2.4970991e+00
   },
}
db.H.grimechThermoCoeffs = {
   notes = 'data from GRIMECH 3.0',
   nsegments = 2, 
   segment0 ={
      T_lower = 200.0,
      T_upper = 1000.0,
      coeffs = {
         0,
         0,
          2.50000000E+00,
          7.05332819E-13,
         -1.99591964E-15,
          2.30081632E-18,
         -9.27732332E-22,
          2.54736599E+04,
         -4.46682853E-01,
      }
   },
   segment1 = {
      T_lower = 1000.0,
      T_upper = 3500.0,
      coeffs = {
         0,
         0,
          2.50000001E+00,
         -2.30842973E-11,
          1.61561948E-14,
         -4.73515235E-18,
          4.98197357E-22,
          2.54736599E+04,
         -4.46682914E-01,
      }
   }
}
