# -*- coding: utf-8 -*-
"""精简输出回调 (compact)

任务开始时记录名称, 仅当任务产生 ok / changed / failed 结果时输出一行任务名;
被 when 跳过的任务 (skipped) 不输出, 避免单独安装组件时出现大量未执行任务.
变更与失败会展开明细, debug 任务的 msg 正常输出.
"""
from __future__ import absolute_import, division, print_function

import time

from ansible.plugins.callback import CallbackBase

DOCUMENTATION = '''
    name: compact
    type: stdout
    short_description: "精简输出 - 只显示实际执行的任务, 跳过的不显示"
'''


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.1
    CALLBACK_TYPE = 'stdout'
    CALLBACK_NAME = 'compact'
    CALLBACK_NEEDS_ENABLED = False

    def __init__(self, display=None):
        super(CallbackModule, self).__init__(display)
        self.started = None
        self._last_debug = {}
        self._task_name = ""
        self._task_printed = True

    # ---------- 生命周期 ----------
    def v2_playbook_on_start(self, playbook):
        self.started = time.time()
        self._display.display("")

    def v2_playbook_on_play_start(self, play):
        self._display.banner("PLAY: %s" % play.get_name().strip())

    def v2_playbook_on_task_start(self, task, is_conditional):
        name = task.get_name().strip()
        # Gathering Facts 为隐式任务, 不单独输出
        self._task_name = "" if name == "Gathering Facts" else name
        self._task_printed = False

    def _ensure_task_line(self):
        """任务首次产生真实结果时输出任务名, 全部 skipped 的任务保持静默."""
        if self._task_printed or not self._task_name:
            return
        self._task_printed = True
        self._display.display("· %s" % self._task_name)

    # ---------- 结果 ----------
    def v2_runner_on_ok(self, result):
        self._ensure_task_line()
        task = result._task
        host = result._host.get_name()
        data = result._result

        # debug 任务: 原样输出 msg (安装结果与配置检查依赖该输出)
        # action 可能为 ansible.builtin.debug 这类带命名空间的全限定名
        if task.action.rsplit('.', 1)[-1] == 'debug':
            lines = self._to_lines(self._debug_value(data))
            if not lines:
                return
            # 多台主机输出相同时仅打印一次, 避免重复输出
            if self._last_debug.get(task.get_name()) == lines:
                return
            self._last_debug[task.get_name()] = lines
            for line in lines:
                self._display.display("    %s" % line)
            return

        if data.get('changed'):
            items = data.get('results')
            if isinstance(items, list) and items:
                changed = sum(1 for i in items if isinstance(i, dict) and i.get('changed'))
                self._display.display("  ✚ %s  (%d 项变更)" % (host, changed), color='yellow')
            else:
                self._display.display("  ✚ %s" % host, color='yellow')

    def v2_runner_on_failed(self, result, ignore_errors=False):
        self._ensure_task_line()
        host = result._host.get_name()
        msg = result._result.get('msg', '') or result._result.get('stderr', '')
        self._display.display("  ✖ %s 失败: %s" % (host, msg), color='red')

    def v2_runner_on_unreachable(self, result):
        self._ensure_task_line()
        self._display.display("  ✖ %s 不可达: %s" % (result._host.get_name(), result._result.get('msg', '')), color='red')

    def v2_runner_on_skipped(self, result):
        pass

    # ---------- 收尾 ----------
    def v2_playbook_on_stats(self, stats):
        self._display.display("")
        self._display.banner("PLAY RECAP")
        for host in sorted(stats.processed.keys()):
            t = stats.summarize(host)
            bad = (t['failures'] or t['unreachable'])
            self._display.display(
                "  %-18s ok=%-3d changed=%-3d failed=%-3d skipped=%-3d unreachable=%d"
                % (host, t['ok'], t['changed'], t['failures'], t['skipped'], t['unreachable']),
                color='red' if bad else 'green',
            )
        if self.started:
            self._display.display("  总用时: %.1f 秒" % (time.time() - self.started))

    @staticmethod
    def _debug_value(data):
        """取出 debug 的显示内容.

        debug 有两种写法:
          msg: ...  结果中包含 msg
          var: xxx  结果中仅包含 {xxx: 值}, 既无 msg 也无 var 字段
        两种写法均兼容, 取不到内容时返回空值, 避免输出空行.
        """
        if 'msg' in data:
            return data['msg']
        skip = ('changed', 'failed', 'skipped', 'msg', 'var', '_ansible_verbose_always',
                '_ansible_no_log', '_ansible_debug', 'invocation')
        for key, value in data.items():
            if key.startswith('_') or key in skip:
                continue
            return value
        return ''

    @staticmethod
    def _to_lines(msg):
        if isinstance(msg, (list, tuple)):
            return [str(m) for m in msg]
        if isinstance(msg, dict):
            return [str(msg)]
        text = str(msg)
        if not text.strip():
            return []
        return text.splitlines() or [text]
