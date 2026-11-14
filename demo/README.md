# Spark 离线演示

从切换器打开 **DeepSeek Harness**，在桌面版按 `Ctrl+O`，选择本仓库的 `demo` 文件夹。也可以先把整个文件夹复制到其他位置再选择。输入框旁选择 **DeepSeek V4.1 Flash**，可把推理等级设为 **Off**。每次复制一条提示词发给模型。

## 读文件和写文件

> 读取 `inventory.csv` 和 `requirements.txt`。在当前文件夹新建 `summary.md`，用中文列出各物资的剩余数量、低库存项和总剩余数量。不要改动原始文件。

打开 `summary.md`，检查结果是否来自表格里的数据。

## 写代码和运行测试

先在 Windows 终端运行 `node --version`。如果系统找不到 `node`，从 [Node.js 官网](https://nodejs.org/en/download) 安装 LTS 版，然后重新打开 DeepSeek Harness。演示使用 Node.js 内置功能，可离线运行。

> 用 Node.js 写 `check-stock.cjs`，读取当前目录的 `inventory.csv`，输出 JSON，其中 `totalRemaining` 是总剩余数量，`restock` 是剩余数量低于阈值的物资名称列表。写一个不依赖第三方包的测试 `check-stock.test.cjs` 并在本地运行，告诉我命令和结果。保留原始文件。

## 识别图片

把 [vision-sample.png](vision-sample.png) 拖到输入框。确认出现缩略图后发送这条消息。

> 看这张图片，分别说出左上、右上和下方的图形、颜色和位置。新建 `vision-notes.md` 记录你看到的内容。

也可以让 Harness 从工作区读取 `vision-sample.png` 后回答同样的问题。
