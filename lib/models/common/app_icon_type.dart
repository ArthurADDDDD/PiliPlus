import 'package:PiliPlus/models/common/enum_with_label.dart';

enum AppIconType with EnumWithLabel {
  bilibili('国际版 bilibili'),
  piliplus('原版 PiliPlus');

  const AppIconType(this.label);

  @override
  final String label;

  bool get isBilibili => this == AppIconType.bilibili;
}
