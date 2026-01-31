// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'enums.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SoundModeAdapter extends TypeAdapter<SoundMode> {
  @override
  final int typeId = 10;

  @override
  SoundMode read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SoundMode.mute;
      case 1:
        return SoundMode.sound;
      case 2:
        return SoundMode.vibrate;
      case 3:
        return SoundMode.soundAndVibrate;
      default:
        return SoundMode.mute;
    }
  }

  @override
  void write(BinaryWriter writer, SoundMode obj) {
    switch (obj) {
      case SoundMode.mute:
        writer.writeByte(0);
        break;
      case SoundMode.sound:
        writer.writeByte(1);
        break;
      case SoundMode.vibrate:
        writer.writeByte(2);
        break;
      case SoundMode.soundAndVibrate:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SoundModeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ThemeModeChoiceAdapter extends TypeAdapter<ThemeModeChoice> {
  @override
  final int typeId = 11;

  @override
  ThemeModeChoice read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return ThemeModeChoice.system;
      case 1:
        return ThemeModeChoice.light;
      case 2:
        return ThemeModeChoice.dark;
      default:
        return ThemeModeChoice.system;
    }
  }

  @override
  void write(BinaryWriter writer, ThemeModeChoice obj) {
    switch (obj) {
      case ThemeModeChoice.system:
        writer.writeByte(0);
        break;
      case ThemeModeChoice.light:
        writer.writeByte(1);
        break;
      case ThemeModeChoice.dark:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThemeModeChoiceAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AppThemeIdAdapter extends TypeAdapter<AppThemeId> {
  @override
  final int typeId = 12;

  @override
  AppThemeId read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AppThemeId.ocean;
      case 1:
        return AppThemeId.forest;
      case 2:
        return AppThemeId.sunset;
      case 3:
        return AppThemeId.mono;
      case 4:
        return AppThemeId.lavender;
      default:
        return AppThemeId.ocean;
    }
  }

  @override
  void write(BinaryWriter writer, AppThemeId obj) {
    switch (obj) {
      case AppThemeId.ocean:
        writer.writeByte(0);
        break;
      case AppThemeId.forest:
        writer.writeByte(1);
        break;
      case AppThemeId.sunset:
        writer.writeByte(2);
        break;
      case AppThemeId.mono:
        writer.writeByte(3);
        break;
      case AppThemeId.lavender:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppThemeIdAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
