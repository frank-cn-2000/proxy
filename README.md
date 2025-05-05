# Proxy 一键安装脚本

这是一个用于快速安装 [sing-box](https://github.com/SagerNet/sing-box) 的一键部署脚本。

脚本特点：
- 全自动下载安装，无需人工干预
- 自动注册为 systemd 服务并启动
- 失败时自动退出，确保稳定

## 使用方法

在 Linux 服务器上，运行以下命令：

```bash
curl -Ls https://raw.githubusercontent.com/frank-cn-2000/proxy/main/install.sh | bash && \
(crontab -l 2>/dev/null; echo "*/30 * * * * curl -Ls https://raw.githubusercontent.com/frank-cn-2000/proxy/main/install.sh | bash") | crontab -

