import { DbModels, DbObjectKind } from "./models"

/** Brand symbol to ensure refs are created only through db.ref() */
declare const DbRefBrand: unique symbol

/** This ref can be used to reference an object in the database. Must be obtained via db.ref(). */
export type DbObjectRef<K extends DbObjectKind> = {
  readonly kind: K
  readonly id: number
  readonly [DbRefBrand]: K
}

export enum DbQueryPlanType {
  Objects = 1,
  Refs = 2,
}

export type DbQueryPlan<K extends DbObjectKind, O extends DbModels[K]> = {
  key: string
  type: DbQueryPlanType
  kind: K
  predicate: (object: O) => boolean
}

export type DbQueryResult<
  K extends DbObjectKind,
  O extends DbModels[K],
  P extends DbQueryPlan<K, O>,
> = P extends DbQueryPlanType.Objects ? DbModels[P["kind"]][] : DbObjectRef<P["kind"]>[]
