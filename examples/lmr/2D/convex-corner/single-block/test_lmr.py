# Author: Rowan J. Gollan
# Date: 2023-05-31
#
# Integration test for convex corner case on single block.

import subprocess
import re
import os

expected_number_steps = 32
expected_final_cfl = 7.292e+03

def expected_output(proc):
    steps = 0
    cfl = 0.0
    lines = proc.stdout.split("\n")
    for line in lines:
        if line.find("FINAL-STEP") != -1:
            steps = int(line.split()[1])
        if line.find("FINAL-CFL") != -1:
            cfl = float(line.split()[1])
    assert steps == expected_number_steps, "Failed to take correct number of steps."
    assert abs(cfl - expected_final_cfl)/expected_final_cfl < 0.005, \
        "Failed to arrive at expected CFL value on final step."


def test_prep():
    make_targets = ['links', 'prep-gas', 'grid', 'init']
    for tgt in make_targets:
        cmd = "make " + tgt
        proc = subprocess.run(cmd.split())
        assert proc.returncode == 0, "Failed during: " + cmd
        
    
def test_run():
    cmd = "lmr run-steady"
    proc = subprocess.run(cmd.split(), capture_output=True, text=True)
    assert proc.returncode == 0, "Failed during: " + cmd
    expected_output(proc)

def test_snapshot():
    cmd = "lmr snapshot2vtk --all"
    proc = subprocess.run(cmd.split())
    assert proc.returncode == 0, "Failed during: " + cmd
    assert os.path.exists('vtk')
    

def test_restart():
    cmd = "lmr run-steady -s 1"
    proc = subprocess.run(cmd.split(), capture_output=True, text=True)
    assert proc.returncode == 0, "Failed during: " + cmd
    expected_output(proc)
    
def test_cleanup():
    cmd = "make clean"
    proc = subprocess.run(cmd.split())
    assert proc.returncode == 0, "Failed during: " + cmd
    
