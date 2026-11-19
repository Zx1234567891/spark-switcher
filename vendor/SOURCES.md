# 上游源码

以下目录保存固定提交的完整 Git 文件树，包括原许可证、声明和可执行权限。部署复制 GLM 和 Qwen 到各自的运行目录，并在那里生成本机配置和应用适配。DeepSeek 控制器使用固定 TensorFold 镜像，按需从随库的源码构建。

| 目录 | 提交与来源 | 许可证 |
| --- | --- | --- |
| `glm/` | [MiaAI-Lab GLM 双 Spark TensorFold，bf5f945](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/tree/bf5f94523a8251029cedae86bf61f8ce37fac218) | [Apache-2.0](glm/LICENSE) · [NOTICE](glm/NOTICE) |
| `deepseek/` | [lucataco DeepSeek 双 Spark，7b46f9d](https://github.com/lucataco/DeepSeek-V4.1-Flash-2x-DGX-Spark/tree/7b46f9d9d8b21357f8998ccce8bdfa857a9ef1ce) | [Apache-2.0](deepseek/LICENSE) · [NOTICE](deepseek/NOTICE) |
| `qwen/` | [MiaAI-Lab Qwen 双 Spark，cd839d0](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks/tree/cd839d0b62f6c737178a0c2037733420e0524ebf) | [AGPL-3.0-or-later](qwen/LICENSE)，个别文件保留原 SPDX 声明 |
| `tensorfold-deepseek/` | [bertholomus TensorFold，8e0966e](https://github.com/bertholomus/TensorFold/tree/8e0966e2b09250abe2f6d9cc51edc20630e6eb1a) | [Apache-2.0](tensorfold-deepseek/LICENSE) · [NOTICE](tensorfold-deepseek/NOTICE) |
| `deepseek-template/` | [DeepSeek V4.1 Flash 聊天模板，314113f](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash/blob/314113f8a7dadb388215396ba5fbee2c610a04d6/chat_template.jinja) | [MIT](deepseek-template/LICENSE) |

模型权重和容器镜像随各资源提供方的条款发布。 [部署与资源清单](../deploy/README.md)
