#!/bin/bash
#
#SBATCH --job-name=mqt-cc-smoke
#SBATCH --output=mqt-cc-smoke.%J.out
#SBATCH --time=00:05:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=512M
#
# Compile for the bundled IQM Garnet model, serialize with iqm-qdmi, and
# check the measured outputs with local DDSIM. No QPU or credentials needed.

set -euo pipefail

MQT_CC_VENV="${MQT_CC_VENV:-/opt/openqse/mqt-cc-venv}"
if [ ! -x "${MQT_CC_VENV}/bin/python" ]; then
    echo "No mqt-cc environment at ${MQT_CC_VENV}. Build the image or run ./do_qfw_build.sh." >&2
    exit 1
fi

echo "[$(date)] mqt-cc-smoke on $(hostname)"

"${MQT_CC_VENV}/bin/python" - <<'PY'
import json

from qiskit import QuantumCircuit, qasm3

from mqt.core.mlir import (
    CompilerTarget,
    OutputFormat,
    PayloadFormat,
    PayloadSpecification,
    TargetEnvironment,
    compile_program,
)
from mqt.core.plugins.qiskit import QDMIBackend, program_serializer
from mqt.core.qdmi import ProgramFormat
from mqt.core.qdmi.driver import open_device

model = open_device("mqt.sc.iqm.garnet")
target = CompilerTarget.from_device(model)
backend = QDMIBackend(device=model)
serializer = program_serializer(ProgramFormat.IQM_JSON)
assert serializer is not None, "iqm-qdmi's IQM JSON serializer is not installed"

# Base-profile restrictions suffice for this static circuit. Stop at native
# gates in QCO; the IQM serializer below owns the final payload format.
environment = TargetEnvironment(
    target,
    PayloadSpecification(PayloadFormat("qir", "2.1.0", "base")),
)

circuit = QuantumCircuit(3, 3)
circuit.h(0)
circuit.cx(0, 2)
circuit.x(1)
# The fixed bit distinguishes measurement order from physical qubit order.
circuit.measure([2, 0, 1], [0, 1, 2])

simulator = open_device("mqt.ddsim.default")
for frontend, source in (("Qiskit", circuit), ("OpenQASM", qasm3.dumps(circuit))):
    program = compile_program(source, output=OutputFormat.QCO_OPTIMIZED)
    program.compile_for_target(environment)
    native = program.to_qiskit(target=target)

    for instruction in native.data:
        qubits = tuple(native.find_bit(qubit).index for qubit in instruction.qubits)
        assert backend.target.instruction_supported(
            operation_name=instruction.operation.name,
            qargs=qubits,
            parameters=instruction.operation.params,
        ), f"Non-native operation or placement: {instruction.operation.name} {qubits}"

    payload = json.loads(serializer(native, backend))
    assert {op["name"] for op in payload["instructions"]} == {"prx", "cz", "measure"}
    site_names = {site.name() for site in model.sites()}
    assert all(set(op["locus"]) <= site_names for op in payload["instructions"])
    print(f"[mqt-cc-smoke] {frontend} -> mqt-cc -> native IQM JSON: OK")

    job = simulator.submit_job(
        qasm3.dumps(native),
        ProgramFormat.QASM3,
        256,
        custom1=7,
    )
    job.wait()
    counts = job.get_counts()
    assert sum(counts.values()) == 256, counts
    assert set(counts) == {"100", "111"}, counts
    print(f"[mqt-cc-smoke] {frontend} compiled circuit -> local DDSIM: {counts}")

print("MQT-CC + IQM SERIALIZATION SMOKE: PASS")
PY
