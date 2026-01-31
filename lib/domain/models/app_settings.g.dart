// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_settings.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AppSettingsAdapter extends TypeAdapter<AppSettings> {
  @override
  final int typeId = 0;

  @override
  AppSettings read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AppSettings(
      themeModeChoice: fields[0] as ThemeModeChoice,
      themeId: fields[1] as AppThemeId,
      soundMode: fields[2] as SoundMode,
      defaultThreshold: fields[3] as int?,
      defaultRepeatInterval: fields[4] as int?,
      tapZoneRatio: fields[5] as double,
      confirmReset: fields[6] as bool,
      keepScreenOn: fields[7] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, AppSettings obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.themeModeChoice)
      ..writeByte(1)
      ..write(obj.themeId)
      ..writeByte(2)
      ..write(obj.soundMode)
      ..writeByte(3)
      ..write(obj.defaultThreshold)
      ..writeByte(4)
      ..write(obj.defaultRepeatInterval)
      ..writeByte(5)
      ..write(obj.tapZoneRatio)
      ..writeByte(6)
      ..write(obj.confirmReset)
      ..writeByte(7)
      ..write(obj.keepScreenOn);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettingsAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
