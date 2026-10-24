const before = await eda.dmt_Project.getCurrentProjectInfo();
if (before.name !== 'AHCT125-LED-R1') throw Error('Unexpected project');
const board = before.data?.length ? before.data[0].uuid : await eda.dmt_Board.createBoard();
const info = await eda.dmt_Board.getBoardInfo(board);
return {project: await eda.dmt_Project.getCurrentProjectInfo(), board, info,
        projectPaths: await eda.sys_FileSystem.getProjectsPaths()};
