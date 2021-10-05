-- prep-grids.lua
-- A place to put helper functions and classes for grid-preparation activities.
-- This script is read by the Eilmer4 program at grid-preparation time,
-- before reading and processing the user's input script.
--
-- Authors: PJ, RJG, Kyle D., Nick G. and Daryl B.
--
if false then -- debug
   print("Begin loading prep-grids.lua.")
end

require 'configoptions'
config = configoptions.config

require 'lua_helper'
deepclone = lua_helper.deepclone
checkAllowedNames = lua_helper.checkAllowedNames

require 'blk_conn'
-- Let's pull the symbols out of the blk_conn module
-- and make them global in this namespace
for k,v in pairs(blk_conn) do
   _G[k] = v
end

require 'gridpro'
-- Make these functions global so that users may call them
-- in the configuration script
applyGridproConnectivity = gridpro.applyGridproConnectivity
applyGridproBoundaryConditions = gridpro.applyGridproBoundaryConditions
to_eilmer_axis_map = gridpro.to_eilmer_axis_map

require 'gridarray'
GridArray = gridarray.GridArray

-------------------------------------------------------------------------

gridsList = {} -- to hold RegisteredGrid objects
gridsDict = {}

--
-- We will store a table of information on each grid that is registered.
--
RegisteredGrid = {
   myType = "RegisteredGrid"
}

function RegisteredGrid:new(o)
   -- Input:
   -- A single table with named items.
   -- grid: a StructuredGrid or UnstructuredGrid object that has been generated
   --    or imported.
   -- tag: a string to identify the grid later in the user's script
   -- fsTag: a string that will be used to select the initial flow condition from
   --    a dictionary when the FluidBlock is later constructed.
   -- bcTags: a table of strings that will be used to attach boundary conditions
   --    from a dictionary when the FluidBlock is later constructed.
   -- gridArrayId: needs to be supplied only if the grid is part of a larger array.
   local flag = type(self)=='table' and self.myType=='RegisteredGrid'
   if not flag then
      error("Make sure that you are using RegisteredGrid:new{} and not RegisteredGrid.new{}", 2)
   end
   local flag = type(o)=='table'
   if not flag then
      error("RegisteredGrid constructor expects a single table with named items.", 2)
   end
   flag = checkAllowedNames(o, {"grid", "tag", "fsTag", "bcTags", "gridArrayId"})
   if not flag then
      error("Invalid name for item supplied to RegisteredGrid constructor.", 2)
   end
   setmetatable(o, self)
   self.__index = self
   -- Make a record of the new object, for later use.
   -- Note that we want id to start at zero for the D code.
   o.id = #gridsList
   gridsList[#gridsList+1] = o
   o.tag = o.tag or string.format("Grid-%d", o.id)
   if gridsDict[o.tag] then
      error('Have previously defined a Grid with tag "' .. o.tag .. '"', 2)
   end
   gridsDict[o.tag] = o.id
   -- Set to -1 if NOT part of a grid-array, otherwise use supplied value
   o.gridArrayId = o.gridArrayId or -1
   -- Initial FlowState tag
   o.fsTag = o.fsTag or ""
   -- Must have a grid.
   assert(o.grid, "need to supply a grid")
   -- Check the grid information.
   if config.dimensions ~= o.grid:get_dimensions() then
      local msg = string.format("Mismatch in dimensions, config %d grid %d.",
				config.dimensions, o.grid.get_dimensions())
      error(msg)
   end
   o.type = o.grid:get_type()
   if o.type == "structured_grid" then
      -- Extract some information from the StructuredGrid
      -- Note 0-based indexing for vertices and cells.
      o.nic = o.grid:get_niv() - 1
      o.njc = o.grid:get_njv() - 1
      if config.dimensions == 3 then
	 o.nkc = o.grid:get_nkv() - 1
      else
	 o.nkc = 1
      end
      o.ncells = o.nic * o.njc * o.nkc
      -- The following table p for the corner locations,
      -- is to be used later for testing for grid connections.
      o.p = {}
      if config.dimensions == 3 then
	 o.p[0] = o.grid:get_vtx(0, 0, 0)
	 o.p[1] = o.grid:get_vtx(o.nic, 0, 0)
	 o.p[2] = o.grid:get_vtx(o.nic, o.njc, 0)
	 o.p[3] = o.grid:get_vtx(0, o.njc, 0)
	 o.p[4] = o.grid:get_vtx(0, 0, o.nkc)
	 o.p[5] = o.grid:get_vtx(o.nic, 0, o.nkc)
	 o.p[6] = o.grid:get_vtx(o.nic, o.njc, o.nkc)
	 o.p[7] = o.grid:get_vtx(0, o.njc, o.nkc)
      else
	 o.p[0] = o.grid:get_vtx(0, 0)
	 o.p[1] = o.grid:get_vtx(o.nic, 0)
	 o.p[2] = o.grid:get_vtx(o.nic, o.njc)
	 o.p[3] = o.grid:get_vtx(0, o.njc)
      end
      --[[print("Grid id=", o.id, "p0=", tostring(o.p[0]), "p1=", tostring(o.p[1]),
         "p2=", tostring(o.p[2]), "p3=", tostring(o.p[3])) ]]
      -- Attach default boundary conditions for those not specified.
      for _,face in ipairs(faceList(config.dimensions)) do
	 o.bcTags[face] = o.bcTags[face] or ""
      end
   end
   if o.type == "unstructured_grid" then
      -- Extract some information from the UnstructuredGrid
      o.ncells = o.grid:get_ncells()
      o.nvertices = o.grid:get_nvertices()
      o.nfaces = o.grid:get_nfaces()
      o.nboundaries = o.grid:get_nboundaries()
      -- Attach boundary conditions from list or from the dictionary of conditions.
      for i = 0, o.nboundaries-1 do
         o.bcTags[i] = o.grid:get_boundaryset_tag(i)
      end
   end
   return o
end -- RegisteredGrid:new

function RegisteredGrid:tojson()
   str = '{\n'
   str = str .. string.format('  "tag": "%s",\n', self.tag)
   str = str .. string.format('  "fsTag": "%s",\n', self.fsTag)
   str = str .. string.format('  "type": "%s",\n', self.type)
   if self.type == "structured_grid" then
      str = str .. string.format('  "dimensions": %d,\n', self.grid:get_dimensions())
      str = str .. string.format('  "niv": %d,\n', self.grid:get_niv())
      str = str .. string.format('  "njv": %d,\n', self.grid:get_njv())
      str = str .. string.format('  "nkv": %d,\n', self.grid:get_nkv())
      str = str .. string.format('  "nic": %d,\n', self.nic)
      str = str .. string.format('  "njc": %d,\n', self.njc)
      str = str .. string.format('  "nkc": %d,\n', self.nkc)
      local fmt = '  "p%d": {"x":%.18e, "y":%.18e, "z":%.18e},\n'
      for i=0, 3 do
         str = str .. string.format(fmt, i, self.p[i].x, self.p[i].y, self.p[i].z)
      end
      if config.dimensions == 3 then
         for i=4, 7 do
            str = str .. string.format(fmt, i, self.p[i].x, self.p[i].y, self.p[i].z)
         end
      end
   else -- unstructured-grid
      str = str .. string.format('  "dimensions": %d,\n', self.grid:get_dimensions())
      str = str .. string.format('  "nvertices": %d,\n', self.grid:get_nvertices())
      str = str .. string.format('  "ncells": %d,\n', self.grid:get_ncells())
      str = str .. string.format('  "nfaces": %d,\n', self.grid:get_nfaces())
      str = str .. string.format('  "nboundaries": %d,\n', self.grid:get_nboundaries())
   end
   str = str .. '  "bcTags": {\n'
   if self.type == "structured_grid" then
      for k, v in pairs(self.bcTags) do
         str = str .. string.format('    "%s": "%s",\n', k, v) -- Expect named boundaries
      end
   else -- unstructured_grid
      for j, v in ipairs(self.bcTags) do
         str = str .. string.format('    "%d": "%s",\n', j-1, v) -- Dlang index will start at zero.
      end
   end
   str = str .. '    "dummy": "xxxx"\n'
   str = str .. '  },\n'
   str = str .. string.format('  "gridArrayId": %d\n', self.gridArrayId) -- last item, no comma
   str = str .. '}\n'
   return str
end -- end RegisteredGrid:tojson()


function registerGrid(o)
   -- Input:
   -- A single table with named items.
   -- grid: a StructuredGrid or UnstructuredGrid object that has been generated
   --    or imported.
   -- tag: a string to identify the grid later in the user's script
   -- fsTag: a string that will be used to select the initial flow condition from
   --    a dictionary when the FluidBlock is later constructed.
   -- bcTags: a table of strings that will be used to attach boundary conditions
   --    from a dictionary when the FluidBlock is later constructed.
   -- gridArrayId: needs to be supplied only if the grid is part of a larger array.
   --
   -- Returns:
   -- the grid id number so that we may assign it and use it when making connections.
   --
   local rgrid = RegisteredGrid:new(o)
   return rgrid.id
end -- function registerGrid

--
-- Structured grids may be connected full face to full face.
--
connectionList = {}

function connectGrids(idA, faceA, idB, faceB, orientation)
   if false then -- debug
      print(string.format('connectGrids(idA=%d, faceA="%s", idB=%d, faceB="%s", orientation=%d)',
                          idA, faceA, idB, faceB, orientation))
   end
   local gridA = gridsList[idA+1] -- Note that the id values start at zero.
   local gridB = gridsList[idB+1]
   if gridA.grid:get_type() ~= "structured_grid" or gridB.grid:get_type() ~= "structured_grid" then
      error("connectGrids() Works only for structured grids.", 2)
   end
   connectionList[#connectionList+1] = {idA=idA, faceA=faceA, idB=idB, faceB=faceB, orientation=orientation}
end

function connectionAsJSON(c)
   str = string.format('{"idA": %d, "faceA": "%s", "idB": %d, "faceB": "%s", "orientation": %d}',
                       c.idA, c.faceA, c.idB, c.faceB, c.orientation)
   return str
end


function identifyGridConnections(includeList, excludeList, tolerance)
   -- Identify grid connections by trying to match corner points.
   -- Parameters (all optional):
   -- includeList: the list of structured grid objects to be included in the search.
   --    If nil, the whole collection is searched.
   -- excludeList: list of pairs of structured grid objects that should not be
   --    included in the search for connections.
   -- tolerance: spatial tolerance for the colocation of vertices
   --
   local myGridList = {}
   if includeList then
      -- The caller has provided a list of grids to bound the search.
      for _,v in ipairs(includeList) do myGridList[#myGridList+1] = v end
   else
      -- The caller has not provided a list; use the global grids list.
      for _,v in ipairs(gridsList) do myGridList[#myGridList+1] = v end
   end
   excludeList = excludeList or {}
   -- Put unstructured grid objects into the exclude list because they don't
   -- have a simple topology that can always be matched to a structured grid.
   for _,A in ipairs(myGridList) do
      if A.grid:get_type() == "unstructured_grid" then excludeList[#excludeList+1] = A end
   end
   if false then -- debug
      print('myGridList=[')
      for _,A in ipairs(myGridList) do print('  ', A.id, ',') end
      print(']')
   end
   tolerance = tolerance or 1.0e-6
   --
   for _,A in ipairs(myGridList) do
      for _,B in ipairs(myGridList) do
	 if (A ~= B) and (not isPairInList({A, B}, excludeList)) then
	    -- print("Proceed with test for coincident vertices.") -- DEBUG
	    local connectionCount = 0
	    if config.dimensions == 2 then
	       -- print("2D test A.id=", A.id, " B.id=", B.id) -- DEBUG
	       for vtxPairs,connection in pairs(connections2D) do
                  if false then -- debug
                     print("vtxPairs=", tostringVtxPairList(vtxPairs),
                           "connection=", tostringConnection(connection))
                  end
                  if verticesAreCoincident(A, B, vtxPairs, tolerance) then
		     local faceA, faceB, orientation = unpack(connection)
		     connectGrids(A.id, faceA, B.id, faceB, 0)
		     connectionCount = connectionCount + 1
		  end
	       end
	    else
	       -- print("   3D test")
               for vtxPairs,connection in pairs(connections3D) do
		  if verticesAreCoincident(A, B, vtxPairs, tolerance) then
		     local faceA, faceB, orientation = unpack(connection)
		     connectBlocks(A.id, faceA, B.id, faceB, orientation)
		     connectionCount = connectionCount + 1
		  end
	       end
	    end
	    if connectionCount > 0 then
	       -- So we don't double-up on connections.
	       excludeList[#excludeList+1] = {A,B}
	    end
	 end -- if (A ~= B...
      end -- for _,B
   end -- for _,A
end -- identifyGridConnections


--
-- A GridArray will be a single, structured grid split into a number of sub-grids.
-- RegisteredGridArray objects hold a GridArray object and some metadata that is needed
-- for the staged preparation.
--
gridArraysList = {} -- to hold RegisteredGridArray objects

RegisteredGridArray = {
   myType = "RegisteredGridArray"
}

function RegisteredGridArray:new(o)
   -- Input:
   -- A single table with named items.
   -- grid: a StructuredGrid object that has been generated or imported.
   -- gridArray: a GridArray object or array of StructuredGrid objects
   -- tag: a string to identify the gridArray later in the user's script
   -- fsTag: a string that will be used to select the initial flow condition from
   --    a dictionary when the FluidBlocks are later constructed.
   -- bcTags: a table of strings that will be used to attach boundary conditions
   --    from a dictionary when the FluidBlocks are later constructed.
   --
   local flag = type(self)=='table' and self.myType=='RegisteredGridArray'
   if not flag then
      error("Make sure that you are using RegisteredGridArray:new{} and not RegisteredGridArray.new{}", 2)
   end
   local flag = type(o)=='table'
   if not flag then
      error("RegisterGridArray expected to receive a single table with named entries", 2)
   end
   local flag = checkAllowedNames(o, {"grid", "gridArray", "tag", "fsTag", "bcTags", "nib", "njb", "nkb"})
   if not flag then
      error("Invalid name for item supplied to RegisteredGridArray constructor.", 2)
   end
   setmetatable(o, self)
   self.__index = self
   -- Make a record of the new object, for later use.
   -- Note that we want id to start at zero for the D code.
   o.id = #gridArraysList
   gridArraysList[#gridArraysList+1] = o
   --
   o.tag = o.tag or ""
   o.fsTag = o.fsTag or ""
   o.bcTags = o.bcTags or {} -- for boundary conditions to be applied to the FluidBlocks
   for _,face in ipairs(faceList(config.dimensions)) do
      o.bcTags[face] = o.bcTags[face] or ""
   end
   if (not o.grid) and (not o.gridArray) then
      error("You need to supply a grid or gridArray to registergridArray.", 2)
   end
   if o.grid then
      -- We will take a single grid and divide it into an array of subgrids.
      if (not o.grid.get_type) or o.grid:get_type() ~= "structured_grid" then
         error("You need to supply a structured_grid to registerGridArray.", 2)
      end
      -- Numbers of subblocks in each coordinate direction
      local nib = o.nib or 1
      local njb = o.njb or 1
      local nkb = o.nkb or 1
      if config.dimensions == 2 then
         nkb = 1
      end
      o.gridArray = GridArray:new{grid=o.grid, nib=nib, njb=njb, nkb=nkb}
   else
      -- We were not given a single grid,
      -- so we assume that we were given the array of subgrids.
      -- Join these into a single overall grid.
      if o.gridArray.myType and o.gridArray.myType == "GridArray" then
         -- The GridArray object is already constructed, so we leave it as is.
      else
         if type(o.gridArray) == "table" then
            o.gridArray = GridArray:new{gridArray=o.gridArray}
         else
            error("gridArray should be an array of grid objects.", 2)
         end
      end
   end
   --
   -- At this point, we have an array of grids and the overall grid.
   local gridCollection = {}
   for ib = 1, o.nib do
      for jb = 1, o.njb do
	 if config.dimensions == 2 then
	    -- 2D flow
	    local subgrid = o.gridArray.grids[ib][jb]
	    local bcTags = {north="", east="", south="", west=""}
	    if ib == 1 then bcTags['west'] = o.bcTags['west'] end
	    if ib == o.gridArray.nib then bcTags['east'] = o.bcTags['east'] end
	    if jb == 1 then bcTags['south'] = o.bcTags['south'] end
	    if jb == o.gridArray.njb then bcTags['north'] = o.bcTags['north'] end
	    local rgrid = RegisteredGrid:new{grid=subgrid, fsTag=o.fsTag, bcTags=bcTags, gridArrayId=id}
	    gridCollection[#gridCollection+1] = rgrid
	 else
	    -- 3D flow, need one more level in the array
	    for kb = 1, o.nkb do
	       local subgrid = o.gridArray.grids[ib][jb][kb]
	       local bcTags = {north="", east="", south="", west="", top="", bottom=""}
	       if ib == 1 then bcTags['west'] = o.bcTags['west'] end
	       if ib == o.gridArray.nib then bcTags['east'] = o.bcTags['east'] end
	       if jb == 1 then bcTags['south'] = o.bcTags['south'] end
	       if jb == o.gridArray.njb then bcTags['north'] = o.bcTags['north'] end
	       if kb == 1 then bcTags['bottom'] = o.bcTags['bottom'] end
	       if kb == o.gridArray.nkb then bcTags['top'] = o.bctags['top'] end
	       local rgrid = RegisteredGrid:new{grid=subgrid, fsTag=o.fsTag, bcTags=bcTags, gridArrayId=id}
	       gridCollection[#gridCollection+1] = rgrid
	    end -- kb loop
	 end -- dimensions
      end -- jb loop
   end -- ib loop
   -- Make the inter-subblock connections
   if #gridCollection > 1 then
      identifyGridConnections(gridCollection)
   end
   --
   return o
end -- RegisteredGridArray:new()

function RegisteredGridArray:tojson()
   -- [TODO] PJ 2021-10-04 finish this function.
   str = '{\n'
   str = str .. string.format('  "tag": "%s",\n', self.tag)
   str = str .. string.format('  "fsTag": "%s",\n', self.fsTag)
   str = str .. string.format('  "type": "%s",\n', self.myType)
   str = str .. '  ' .. self.gridArray:tojson()
   str = str .. '}\n'
   return str
end -- end RegisteredGridArray:tojson()


function registerGridArray(o)
   -- Input:
   -- A single table with named items.
   -- grid: a StructuredGrid object that has been generated or imported.
   -- tag: a string to identify the gridArray later in the user's script
   -- fsTag: a string that will be used to select the initial flow condition from
   --    a dictionary when the FluidBlocks are later constructed.
   -- bcTags: a table of strings that will be used to attach boundary conditions
   --    from a dictionary when the FluidBlocks are later constructed.
   --
   -- Returns:
   -- the id of RegisteredGridArray object so that the user may use the interior pieces later in their script.
   local rga = RegisteredGridArray:new(o)
   return rga.id
end -- registerGridArray

--
-- IO functions to write the grid and connection files.
--
function writeGridFiles(jobName)
   print(string.format('Write grid files for job="%s"', jobName))
   --
   os.execute("mkdir -p grid")
   local fileName = "grid/" .. jobName .. ".grid-metadata"
   local f = assert(io.open(fileName, "w"))
   f:write('{\n')
   f:write(string.format('  "ngrids": %d,\n', #gridsList))
   f:write(string.format('  "ngridarrays": %d,\n', #gridArraysList))
   if #gridArraysList > 0 then
      f:write('  "gridarrays": [')
      for i,ga in ipairs(gridArraysList) do
         f:write('    ' .. ga:tojson())
         if i < #gridArraysList then f:write(',') end
         f:write('\n')
      end
      f:write('  ],\n')
   end
   f:write('  "grid-connections": [\n')
   for i, c in ipairs(connectionList) do
      f:write('    ' .. connectionAsJSON(c))
      if i < #connectionList then f:write(',\n') else f:write('\n') end
   end
   f:write('  ]\n') -- Note last item has no comma.
   f:write('}\n')
   f:close()
   print(string.format("  #connections: %d", #connectionList))
   --
   os.execute("mkdir -p grid/t0000")
   for i, g in ipairs(gridsList) do
      if false then -- May activate print statement for debug.
         print("grid id=", g.id)
      end
      -- Write the grid proper.
      local fileName = "grid/t0000/" .. jobName .. string.format(".grid.b%04d.t0000", g.id)
      if config.grid_format == "gziptext" then
	 g.grid:write_to_gzip_file(fileName .. ".gz")
      elseif config.grid_format == "rawbinary" then
	 g.grid:write_to_raw_binary_file(fileName .. ".bin")
      else
	 error(string.format("Oops, invalid grid_format: %s", config.grid_format))
      end
      -- Write the grid metadata.
      local fileName = "grid/" .. jobName .. string.format(".grid.b%04d.metadata", g.id)
      local f = assert(io.open(fileName, "w"))
      f:write(g:tojson() .. '\n')
      f:close()
   end
   print(string.format("  #grids %d", #gridsList))
   --
   -- [TODO] PJ 2021-10-04, write RegisteredGridArrays data.
end
