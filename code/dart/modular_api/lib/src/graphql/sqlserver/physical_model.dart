enum PhysicalObjectKind {
  table,
  view,
}

final class PhysicalCatalog {
  const PhysicalCatalog({required this.objects});

  final List<PhysicalObject> objects;
}

final class PhysicalObject {
  const PhysicalObject({
    required this.id,
    required this.kind,
    required this.schemaName,
    required this.objectName,
    required this.identityFields,
    required this.fields,
    required this.relations,
  });

  final String id;
  final PhysicalObjectKind kind;
  final String schemaName;
  final String objectName;
  final List<String> identityFields;
  final List<PhysicalField> fields;
  final List<PhysicalRelationSeed> relations;
}

final class PhysicalField {
  const PhysicalField({
    required this.column,
    required this.nativeType,
    required this.nullable,
  });

  final String column;
  final String nativeType;
  final bool nullable;
}

final class PhysicalRelationSeed {
  const PhysicalRelationSeed({
    required this.name,
    required this.sourceObjectId,
    required this.targetObjectId,
    required this.sourceFields,
    required this.targetFields,
  });

  final String name;
  final String sourceObjectId;
  final String targetObjectId;
  final List<String> sourceFields;
  final List<String> targetFields;
}