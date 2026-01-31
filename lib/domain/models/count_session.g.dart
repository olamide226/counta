// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'count_session.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CountSessionAdapter extends TypeAdapter<CountSession> {
  @override
  final int typeId = 1;

  @override
  CountSession read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CountSession(
      id: fields[0] as String?,
      mantra: fields[1] as String,
      startedAt: fields[2] as DateTime,
      endedAt: fields[3] as DateTime,
      finalCount: fields[4] as int,
      threshold: fields[5] as int?,
      repeatInterval: fields[6] as int?,
      soundMode: fields[7] as SoundMode,
      themeModeChoice: fields[8] as ThemeModeChoice,
      themeId: fields[9] as AppThemeId,
      notes: fields[10] as String?,
      deviceLocale: fields[11] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, CountSession obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.mantra)
      ..writeByte(2)
      ..write(obj.startedAt)
      ..writeByte(3)
      ..write(obj.endedAt)
      ..writeByte(4)
      ..write(obj.finalCount)
      ..writeByte(5)
      ..write(obj.threshold)
      ..writeByte(6)
      ..write(obj.repeatInterval)
      ..writeByte(7)
      ..write(obj.soundMode)
      ..writeByte(8)
      ..write(obj.themeModeChoice)
      ..writeByte(9)
      ..write(obj.themeId)
      ..writeByte(10)
      ..write(obj.notes)
      ..writeByte(11)
      ..write(obj.deviceLocale);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CountSessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
