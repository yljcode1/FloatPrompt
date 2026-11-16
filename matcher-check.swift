import Foundation
@main struct Checks {
 static func main() {
  var count = 0
  func check(_ condition: Bool, _ name: String) { precondition(condition, name); count += 1 }
  let lines = ["今天聊聊苹果手机的提词器。", "第一个优点是可以自由调整滚动速度。", "第二个优点是完整稿件可以跟随声音。", "最后记得保存视频。"]
  check(ScriptMatcher.locate("第一个优点是可以自由调整滚动速度", lines: lines, current: 0) == 1, "照读定位")
  check(ScriptMatcher.locate("昨天我去公园散步看见很多人在锻炼身体", lines: lines, current: 1) == nil, "扩展时等待")
  check(ScriptMatcher.locate("第二个优点是完整稿件可以跟随声音", lines: lines, current: 1) == 2, "返回稿件")
  check(ScriptMatcher.locate("好", lines: lines, current: 1) == nil, "短语不能触发跳转")
  check(ScriptMatcher.locate("你好世界", lines: [], current: 0) == nil, "空稿件")
  check(ScriptMatcher.locate("最后记得保存视频", lines: lines, current: 999) == 3, "越界进度安全")
  check(ScriptMatcher.locate("最后记得保存视频", lines: lines, current: -10) == 3, "负进度安全")
  check(ScriptMatcher.locate("今天聊聊苹果手机的提词器", lines: [lines[0], lines[0]], current: 0) == nil, "重复句不乱跳")
  let original = "你好，世界！这是第二句。停一下；继续？"
  check(ScriptMatcher.sentences(original).joined() == original, "保留完整标点")
  let long = String(repeating: "完整逐字稿不能丢失内容", count: 30)
  check(ScriptMatcher.sentences(long).joined() == long, "长段落分行不丢字")
  check(ScriptMatcher.sentences(" \n\n").isEmpty, "空白稿件")
  check(ScriptMatcher.normalize("HELLO，世界！123") == "hello世界123", "中英文字归一化")
  let adlib = "第一个优点是可以自由调整滚动速度，但我想起昨天公园有只小狗一直追着皮球跑还撞到了椅子真是好笑后来我们喝了咖啡又聊了很久的天气"
  check(ScriptMatcher.locate(adlib, lines: lines, current: 1) == nil, "不被旧匹配掩盖自由发挥")
  print("\(count) alignment checks passed")
 }
}
