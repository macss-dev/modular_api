export enum PhysicalObjectKind {
  Table = 'table',
  View = 'view',
}

export interface PhysicalCatalog {
  readonly objects: readonly PhysicalObject[];
}

export interface PhysicalObject {
  readonly id: string;
  readonly kind: PhysicalObjectKind;
  readonly schemaName: string;
  readonly objectName: string;
  readonly identityFields: readonly string[];
  readonly fields: readonly PhysicalField[];
  readonly relations: readonly PhysicalRelationSeed[];
}

export interface PhysicalField {
  readonly column: string;
  readonly nativeType: string;
  readonly nullable: boolean;
}

export interface PhysicalRelationSeed {
  readonly name: string;
  readonly sourceObjectId: string;
  readonly targetObjectId: string;
  readonly sourceFields: readonly string[];
  readonly targetFields: readonly string[];
}