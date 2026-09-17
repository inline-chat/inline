import { describe, expect, it } from "bun:test"
import { Readable } from "node:stream"
import {
  CreateMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  ListPartsCommand,
  S3Client,
} from "@aws-sdk/client-s3"

// Exercise the SDK's real XML decoder with synthetic provider responses; no credentials or network.
const clientWithResponse = (xml: string, statusCode = 200) => new S3Client({
  region: "auto", endpoint: "https://storage.example.test", maxAttempts: 1,
  credentials: { accessKeyId: "synthetic", secretAccessKey: "synthetic" },
  requestHandler: {
    async handle() {
      return { response: { statusCode, headers: { "content-type": "application/xml" }, body: Readable.from([Buffer.from(xml)]) } }
    },
  },
})

describe("S3 XML compatibility", () => {
  it("decodes multipart identifiers and ordered parts with XML escapes", async () => {
    const create = clientWithResponse(`<InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Bucket>test</Bucket><Key>photos/a&amp;b.jpg</Key><UploadId>upload&amp;1</UploadId>
    </InitiateMultipartUploadResult>`)
    const list = clientWithResponse(`<ListPartsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Bucket>test</Bucket><Key>photos/a&amp;b.jpg</Key><UploadId>upload&amp;1</UploadId><IsTruncated>false</IsTruncated>
      <Part><PartNumber>1</PartNumber><ETag>&quot;first&quot;</ETag><Size>100</Size></Part>
      <Part><PartNumber>2</PartNumber><ETag>&quot;second&quot;</ETag><Size>20</Size></Part>
    </ListPartsResult>`)
    try {
      expect(await create.send(new CreateMultipartUploadCommand({ Bucket: "test", Key: "photos/a&b.jpg" })))
        .toMatchObject({ Key: "photos/a&b.jpg", UploadId: "upload&1" })
      expect(await list.send(new ListPartsCommand({ Bucket: "test", Key: "photos/a&b.jpg", UploadId: "upload&1" })))
        .toMatchObject({ IsTruncated: false, Parts: [
          { PartNumber: 1, ETag: '"first"', Size: 100 }, { PartNumber: 2, ETag: '"second"', Size: 20 },
        ] })
    } finally { create.destroy(); list.destroy() }
  })

  it("preserves provider errors embedded in successful HTTP multipart responses", async () => {
    const client = clientWithResponse('<Error><Code>InvalidPart</Code><Message>Missing &amp; mismatched part</Message></Error>')
    try {
      await expect(client.send(new CompleteMultipartUploadCommand({
        Bucket: "test", Key: "object", UploadId: "upload", MultipartUpload: { Parts: [{ PartNumber: 1, ETag: '"first"' }] },
      }))).rejects.toMatchObject({ name: "InvalidPart", message: "Missing & mismatched part" })
    } finally { client.destroy() }
  })
})
