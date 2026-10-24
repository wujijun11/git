const project = await eda.dmt_Project.getCurrentProjectInfo();
if (!project.name.includes('AHCT125-LED-R1')) throw Error('Unexpected project');
const board = project.data[0];
await eda.dmt_EditorControl.openDocument(board.schematic.page[0].uuid);
await new Promise(r=>setTimeout(r,8000));
const schematicPassed = await eda.sch_Drc.check(true, false, false);
const schematicViolations = await eda.sch_Drc.check(true, false, true);
await eda.dmt_EditorControl.openDocument(board.pcb.uuid);
await new Promise(r=>setTimeout(r,8000));
const components = (await eda.pcb_PrimitiveComponent.getAll()).length;
const pcbPassed = await eda.pcb_Drc.check(true, false, false);
const pcbViolations = await eda.pcb_Drc.check(true, false, true);
return {project:project.name, schematicPassed, schematicViolations,
        pcbPassed, pcbViolations, components};
