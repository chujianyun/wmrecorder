#!/usr/bin/env python3
"""Create a reviewable report without copying recordings or certificate details."""
import argparse
import datetime
import json
import pathlib
import plistlib
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--e2e', required=True, type=pathlib.Path)
parser.add_argument('--unit-log', required=True, type=pathlib.Path)
parser.add_argument('--output', required=True, type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
result = json.loads((args.e2e / 'test-results.json').read_text())
if not result.get('finished'):
    raise SystemExit('Device tests have not finished; refusing to publish a completion report.')
log = args.unit_log.read_text()
counts = re.findall(r'Executed (\d+) tests, with (\d+) failures?', log)
if not counts:
    raise SystemExit('No executed XCTest results found.')
unit_total, unit_failed = map(int, counts[-1])
app = pathlib.Path('/Applications/WMRecorder.app')
with (app / 'Contents/Info.plist').open('rb') as handle:
    installed = plistlib.load(handle)
source_hash = subprocess.check_output(['python3', 'scripts/source-fingerprint.py'], cwd=root, text=True).strip()
if source_hash != installed.get('WMSourceFingerprint') or source_hash != result.get('sourceFingerprint'):
    raise SystemExit('Source, installed app and device-test fingerprints differ.')
verify = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True, text=True)
if verify.returncode:
    raise SystemExit('Installed code signature validation failed.')
try:
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
except subprocess.CalledProcessError:
    revision = '尚未提交；以源码指纹为准'
now = datetime.datetime.now().astimezone().isoformat(timespec='seconds')

def clean(text):
    text = text.split('; file=')[0]
    text = text.replace(str(pathlib.Path.home()), '<用户目录>')
    return text.replace('|', '\\|').replace('\n', ' ')

rows = '\n'.join(f"| {r['name']} | {r['status']} | {clean(r['detail'])} |" for r in result['rows'])
status = '通过' if unit_failed == 0 and result['failed'] == 0 and result['blocked'] == 0 else '未全部通过'
report = f'''# WMRecorder 安装与测试记录

生成时间：{now}。总体状态：**{status}**。

## 版本与环境

- 源码提交：`{revision}`。文档与本报告后续提交不改变应用源码指纹。
- 源码、安装包和本次设备测试共同指纹：`{source_hash}`。
- 应用版本：{installed['CFBundleShortVersionString']}（{installed['CFBundleVersion']}）。
- 测试环境：Apple Silicon，macOS 26.6.2，Swift 6.3.3，FFmpeg 9.0.1。
- 实际安装与运行路径：`/Applications/WMRecorder.app`。
- 首次安装无旧应用基线；随后多轮更新沿用同一 Apple Development 身份。具体证书身份和原始日志只留本机。

## 已执行命令与结果

| 检查 | 结果 |
| --- | --- |
| `swift test` | {unit_total} 项，失败 {unit_failed} 项 |
| `./scripts/build.sh` | release 构建通过，签名完整性与旧 DR 兼容性检查通过 |
| `./scripts/install.sh --args --self-test <本机测试目录> --stress-seconds 60` | 已正常退出空闲旧进程、完整替换并启动固定安装路径 |
| `codesign --verify --deep --strict /Applications/WMRecorder.app` | 本报告生成时再次通过 |
| 源码／产物／测试指纹比对 | 三者一致 |
| 设备与录制自检 | {result['passed']} 通过，{result['failed']} 失败，{result['blocked']} 阻塞标记 |
| 界面导出后的 `ffprobe` | 320 × 180、30 fps、1.000 秒、包含音轨；源文件保留 |
| GUI 实际查看与操作 | 录制、区域拖选、媒体库播放、编辑预览及导出、偏好与快捷键编辑已操作和查看 |

## 自动设备测试

每个录制文件通过媒体探测与解码检查；涉及相机时额外检查原始输入像素，避免仅以回调帧数判定成功。原始 JSON、日志、屏幕和相机片段留在 Git 忽略的本机目录，不上传。

| 用例 | 结果 | 实际证据 |
| --- | --- | --- |
{rows}

## 单元与媒体处理测试范围

参数边界、选择来源约束、配置序列化、无效裁剪和时间范围、禁止覆盖输入、特殊字符文件名、真实截取／裁剪／缩放／帧率转换、双音轨保留、混音、静音、单声道、音量减半后的实际波形幅值、单轨提取、GIF／MP3／MKV、损坏素材、导出取消保留源文件，以及镜像、四角画中画、边框和宽高比的像素级校验。

## 实际界面验收

- 区域拖选完成后，X／Y／宽／高正确回填；可修改输出尺寸与定时停止秒数。
- 通过界面执行倒计时、区域录制和自动停止，文件出现在媒体库；播放器切换到播放状态。
- 编辑页设置 0.2–1.2 秒与 320 × 180，预览后通过系统保存面板导出；真实文件为 1.000 秒。
- 偏好页快捷键由 Control-Command-W 改成 Control-Option-Command-W，再恢复默认；未误触发录制。前台 Control-Command-1 可切换到全屏录制页。
- 录制、编辑、偏好页已查看实际渲染，开始按钮固定在底部，小窗口不必滚动查找。
- 正常交付保持应用启动；测试时修改的分辨率／时长已恢复为 1080p、30 fps、不限时长。

## 发现与修复

1. 签名 DR 表达式需用 `= ` 前缀传给 codesign；已修复，不削弱签名规则。
2. 摄像头首帧较晚时先计时会少录开头，改为等真实媒体数据到达后进入录制状态。
3. 不同摄像头宽高比造成画中画内部大片白色，已分离黑色底板与白色细边框，并补充像素测试。
4. 很早取消导出时，FFmpeg 尚未启动，请求曾丢失；已保存任务级取消状态并增加回归测试。初次回归确实失败，修复后重跑通过。
5. 部分 SwiftUI 分组令桌面工具读取可访问性树时崩溃；显式划分可访问性容器后，录制、编辑和偏好页面操作通过。崩溃进程为桌面测试工具，非 WMRecorder。
6. NSRunningApplication 的退出状态缓存曾导致安装误报未退出，改用操作系统 PID 状态核验；所有替换前仍保留旧安装。
7. 编辑快捷键时临时解除注册，避免编辑本身触发已有动作；补充前台按键路径，结束采集后移除输出并释放会话引用。

## 未完成与适用限制

- **摄像头真实可见画面未通过。** 内置相机返回近乎全黑的原始像素，延长等待仍然如此；可能存在遮挡或环境光不足，当前不能断言具体物理原因。镜像和画中画的合成算法像素测试通过，不能代替实景验收。解除遮挡／改善光线后需重跑这三项。
- 较早版本仅按帧数判断摄像头曾报告通过；视觉复核后增加原始像素检测，最终结论以本报告的失败项为准。
- 系统授权开关与实际录屏调用可用，但录制中观察到 macOS 首次直接访问屏幕／音频的额外确认。是否仍需用户处理该提示尚未确认。工具安全策略禁止检查系统通知中心，未绕过该限制，也未重置权限。
- Carbon 全局热键注册无冲突，前台触发与快捷键重录已验证；桌面工具向其他应用发送的按键没有触发后台热键，物理键盘的后台热键及菜单栏操作仍需人工验收，不写作通过。
- 多显示器、其他外接摄像头／麦克风、其他 macOS 版本、系统保护内容和较长的数小时录制没有在本次机器环境完整验证。当前设备中单显示器、内置音频采集已测试。
- 本次为本机稳定开发签名安装；跨机器分发、公证和 App Store 提交不属于本次已完成结果。

## Git 与隐私

应用源码、构建／安装／测试脚本与脱敏文档纳入版本控制。录制片段、相机画面、临时文件、本机证书选择、个人账号和系统原始日志均在忽略范围内。推送结果在完成远端核对后补充，不能仅凭本地提交声称已推送。
'''
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(report)
print(args.output)
