// exe 進入點
require('./server').main().catch((e) => {
  console.error(e);
  console.log('發生錯誤，按 Enter 關閉');
  process.stdin.once('data', () => process.exit(1));
});
