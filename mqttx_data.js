/**
 * MQTTX CLI Custom Scenario: Mudro Logic Multi-Machine Demo
 * Simulates 3 completely different pieces of equipment concurrently.
 */

// 1. Create a memory bank to remember which client gets which machine type
const assignedRoles = {};
const availableMachines = ['Legacy_Press', 'Assembly_Robot', 'CNC_Mill'];
let machineCounter = 0;

function generator(faker, options) {
  // 2. Identify the specific connection asking for data
  const clientId = options.clientId;

  // 3. If this is a new connection, assign it the next available machine role
  if (!assignedRoles[clientId]) {
    assignedRoles[clientId] = availableMachines[machineCounter % availableMachines.length];
    machineCounter++;
  }

  // 4. Look up what machine this client is supposed to be
  const myMachineType = assignedRoles[clientId];
  let payloadData = { 
    machine_id: clientId,
    type: myMachineType 
  };

  // 5. Generate completely different data based on the machine type
  if (myMachineType === 'Legacy_Press') {
    payloadData.temperature = Math.floor(Math.random() * (200 - 180 + 1)) + 180;
    payloadData.oil_pressure = Math.floor(Math.random() * (55 - 45 + 1)) + 45;
  } 
  else if (myMachineType === 'Assembly_Robot') {
    payloadData.weld_count = Math.floor(Math.random() * 3);
    payloadData.axis_z_position = Math.floor(Math.random() * (105 - 95 + 1)) + 95;
    payloadData.status = "RUNNING";
  } 
  else if (myMachineType === 'CNC_Mill') {
    payloadData.spindle_rpm = Math.floor(Math.random() * (12000 - 11500 + 1)) + 11500;
    payloadData.vibration_hz = parseFloat((Math.random() * 2 + 1).toFixed(2));
    payloadData.coolant_level = "OK";
  }

  // 6. Send the unique payload
  return {
    Message: JSON.stringify(payloadData)
  };
}

module.exports = {
  name: 'mudro_multi_demo',
  generator
};