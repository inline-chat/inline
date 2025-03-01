enum ModelErrorCodes {
  CHAT_INVALID = "CHAT_INVALID",
  MESSAGE_INVALID = "MESSAGE_INVALID",
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
}
