enum ModelErrorCodes {
  CHAT_INVALID = "CHAT_INVALID",
  MESSAGE_INVALID = "MESSAGE_INVALID",
  PHOTO_INVALID = "PHOTO_INVALID",
  VIDEO_INVALID = "VIDEO_INVALID",
  DOCUMENT_INVALID = "DOCUMENT_INVALID",
  FAILED = "FAILED",
}

export class ModelError extends Error {
  public code: ModelErrorCodes

  constructor(code: ModelErrorCodes) {
    super(code)
    this.code = code
  }

  public static Codes = ModelErrorCodes

  // Convinience methods
  public static ChatInvalid = new ModelError(ModelErrorCodes.CHAT_INVALID)
  public static MessageInvalid = new ModelError(ModelErrorCodes.MESSAGE_INVALID)
  public static PhotoInvalid = new ModelError(ModelErrorCodes.PHOTO_INVALID)
  public static VideoInvalid = new ModelError(ModelErrorCodes.VIDEO_INVALID)
  public static DocumentInvalid = new ModelError(ModelErrorCodes.DOCUMENT_INVALID)
  public static Failed = new ModelError(ModelErrorCodes.FAILED)
}
