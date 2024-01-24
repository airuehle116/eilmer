// SPDX-FileCopyrightText: Copyright (c) Kitware Inc.
// SPDX-License-Identifier: BSD-3-Clause

#include <catalyst.h>
#include <stdio.h>

// Datastructure definitions moved here by NNG
// This must be kept consistent with the D version!
typedef struct CatalystData
{
  int dimensions;
  unsigned int NumberOfPoints; // Note the change to from uint64_t
  unsigned int NumberOfCells;  // Also changed to 32 from 64
  unsigned int Cell2VertexSize;
  double* Points;
  long* Cells;

  double* velx;
  double* vely;
  double* velz;
  double* Pressure;
} CatalystData;

//-----------------------------------------------------------------------------
/**
 * Initialize Catalyst.
 */
//-----------------------------------------------------------------------------
void do_catalyst_initialization()
{
  conduit_node* catalyst_init_params = conduit_node_create();
  // no longer pass scripts on the command line, since we won't do this for eilmer.
  conduit_node_set_path_char8_str(catalyst_init_params, "catalyst/scripts/script0", "catalyst_pipeline.py");
  conduit_node_set_path_char8_str(catalyst_init_params, "catalyst_load/implementation", "paraview");
  conduit_node_set_path_char8_str(
    catalyst_init_params, "catalyst_load/search_paths/paraview", "/home/uqngibbo/source/ParaView/build/lib/catalyst");
  enum catalyst_status err = catalyst_initialize(catalyst_init_params);
  conduit_node_destroy(catalyst_init_params);
  if (err != catalyst_status_ok)
  {
    printf("Failed to initialize Catalyst: %d\n", err);
  }
}

//-----------------------------------------------------------------------------
/**
 * Execute per cycle
 */
//-----------------------------------------------------------------------------
void do_catalyt_execute(int cycle, double time, CatalystData* data)
{
  conduit_node* catalyst_exec_params = conduit_node_create();
  conduit_node_set_path_int64(catalyst_exec_params, "catalyst/state/timestep", cycle);
  // one can also use "catalyst/cycle" for the same purpose.
  // conduit_node_set_path_int64(catalyst_exec_params, "catalyst/state/cycle", cycle);
  conduit_node_set_path_float64(catalyst_exec_params, "catalyst/state/time", time);

  // the data must be provided on a named channel. the name is determined by the
  // simulation. for this one, we're calling it "grid".

  // declare the type of the channel; we're using Conduit Mesh Blueprint
  // to describe the mesh and fields.
  conduit_node_set_path_char8_str(catalyst_exec_params, "catalyst/channels/grid/type", "mesh");

  // now, create the mesh.
  conduit_node* mesh = conduit_node_create();

  // add coordsets
  conduit_node_set_path_char8_str(mesh, "coordsets/coords/type", "explicit");
  conduit_node_set_path_char8_str(mesh, "coordsets/coords/type", "explicit");
  conduit_node_set_path_external_float64_ptr_detailed(mesh, "coordsets/coords/values/x",
    /*data=*/data->Points, /*num_elements=*/data->NumberOfPoints, /*offset=*/0,
    /*stride=*/3 * sizeof(double), /*element_bytes=*/sizeof(double),
    /*endianness=*/CONDUIT_ENDIANNESS_DEFAULT_ID);
  conduit_node_set_path_external_float64_ptr_detailed(mesh, "coordsets/coords/values/y",
    /*data=*/data->Points, /*num_elements=*/data->NumberOfPoints, /*offset=*/1 * sizeof(double),
    /*stride=*/3 * sizeof(double), /*element_bytes=*/sizeof(double),
    /*endianness=*/CONDUIT_ENDIANNESS_DEFAULT_ID);
  conduit_node_set_path_external_float64_ptr_detailed(mesh, "coordsets/coords/values/z",
    /*data=*/data->Points, /*num_elements=*/data->NumberOfPoints, /*offset=*/2 * sizeof(double),
    /*stride=*/3 * sizeof(double), /*element_bytes=*/sizeof(double),
    /*endianness=*/CONDUIT_ENDIANNESS_DEFAULT_ID);

  // add topologies
  conduit_node_set_path_char8_str(mesh, "topologies/mesh/type", "unstructured");
  conduit_node_set_path_char8_str(mesh, "topologies/mesh/coordset", "coords");

  // This could be expanded for unstructured
  if (data->dimensions==2) {
      conduit_node_set_path_char8_str(mesh, "topologies/mesh/elements/shape", "quad");
  } else if (data->dimensions==3) {
      conduit_node_set_path_char8_str(mesh, "topologies/mesh/elements/shape", "hex");
  } else {
      printf("Error, incorrect dimensions %d ", data->dimensions);
      exit(1);
  }
  conduit_node_set_path_external_int64_ptr(
      mesh, "topologies/mesh/elements/connectivity", data->Cells, data->Cell2VertexSize);

  // add velocity (cell-field)
  conduit_node_set_path_char8_str(mesh, "fields/velx/association", "element");
  conduit_node_set_path_char8_str(mesh, "fields/velx/topology", "mesh");
  conduit_node_set_path_char8_str(mesh, "fields/velx/volume_dependent", "false");
  conduit_node_set_path_external_float64_ptr(mesh, "fields/velx/values", data->velx, data->NumberOfCells);

  conduit_node_set_path_char8_str(mesh, "fields/vely/association", "element");
  conduit_node_set_path_char8_str(mesh, "fields/vely/topology", "mesh");
  conduit_node_set_path_char8_str(mesh, "fields/vely/volume_dependent", "false");
  conduit_node_set_path_external_float64_ptr(mesh, "fields/vely/values", data->vely, data->NumberOfCells);

  conduit_node_set_path_char8_str(mesh, "fields/velz/association", "element");
  conduit_node_set_path_char8_str(mesh, "fields/velz/topology", "mesh");
  conduit_node_set_path_char8_str(mesh, "fields/velz/volume_dependent", "false");
  conduit_node_set_path_external_float64_ptr(mesh, "fields/velz/values", data->velz, data->NumberOfCells);

  // add pressure (cell-field)
  conduit_node_set_path_char8_str(mesh, "fields/pressure/association", "element");
  conduit_node_set_path_char8_str(mesh, "fields/pressure/topology", "mesh");
  conduit_node_set_path_char8_str(mesh, "fields/pressure/volume_dependent", "false");
  conduit_node_set_path_external_float64_ptr(
    mesh, "fields/pressure/values", data->Pressure, data->NumberOfCells);
  conduit_node_set_path_external_node(catalyst_exec_params, "catalyst/channels/grid/data", mesh);

#if 0
  // print for debugging purposes, if needed
  conduit_node_print(catalyst_exec_params);

  // print information with details about memory allocation
  conduit_node* info = conduit_node_create();
  conduit_node_info(catalyst_exec_params, info);
  conduit_node_print(info);
  conduit_node_destroy(info);
#endif

  enum catalyst_status err = catalyst_execute(catalyst_exec_params);
  if (err != catalyst_status_ok)
  {
    printf("Failed to execute Catalyst: %d\n", err);
  }
  conduit_node_destroy(catalyst_exec_params);
  conduit_node_destroy(mesh);
}

//-----------------------------------------------------------------------------
/**
 * Finalize Catalyst.
 */
//-----------------------------------------------------------------------------
void do_catalyt_finalization()
{
  conduit_node* catalyst_fini_params = conduit_node_create();
  enum catalyst_status err = catalyst_finalize(catalyst_fini_params);
  if (err != catalyst_status_ok)
  {
    printf("Failed to execute Catalyst: %d\n", err);
  }
  conduit_node_destroy(catalyst_fini_params);
}
