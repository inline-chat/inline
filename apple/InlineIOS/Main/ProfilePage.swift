import InlineKit
import InlineUI
import Logger
import MultipartFormDataKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfilePage: View {
  let userInfo: UserInfo
  private let size: CGFloat = 60

  @EnvironmentObject var viewModel: FileUploadViewModel

  private var user: User {
    userInfo.user
  }

  var body: some View {
    NavigationView {
      Form {
        Section {
          HStack(spacing: 16) {
            ProfilePhotoView(viewModel: viewModel, userInfo: userInfo, size: size)

            VStack(alignment: .leading, spacing: 0) {
              Text(user.fullName)
                .font(.body.weight(.semibold))

              if let username = user.username {
                Text("@\(username)")
                  .foregroundColor(.secondary)
              } else if let email = user.email {
                Text(email)
                  .foregroundColor(.secondary)
              }
            }
          }
        }
        Section {
          Button {
            viewModel.showImagePicker = true
          } label: {
            HStack {
              Image(systemName: "camera.fill")
                .font(.callout)
                .foregroundColor(.white)
                .frame(width: 25, height: 25)
                .background(Color.pink)
                .clipShape(RoundedRectangle(cornerRadius: 6))
              Text("Change Profile Photo")
                .foregroundColor(.primary)
                .padding(.leading, 4)
              Spacer()
            }
            .padding(.vertical, 2)
          }
        }
      }
      .navigationTitle("Profile")
      .navigationBarTitleDisplayMode(.inline)
      .formStyle(.grouped)
      .alert(
        viewModel.errorState?.title ?? "",
        isPresented: .init(
          get: { viewModel.errorState != nil },
          set: { if !$0 { viewModel.errorState = nil } }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        if let errorState = viewModel.errorState {
          VStack(alignment: .leading, spacing: 8) {
            Text(errorState.message)
            if let suggestion = errorState.suggestion {
              Text(suggestion)
                .font(.callout)
                .foregroundColor(.secondary)
            }
          }
        }
      }
    }
  }
}

struct ProfilePhotoView: View {
  @ObservedObject var viewModel: FileUploadViewModel
  let userInfo: UserInfo
  let size: CGFloat

  var body: some View {
    Button {
      viewModel.showImagePicker = true
    } label: {
      ZStack {
        UserAvatar(userInfo: userInfo, size: size)
          .overlay(
            Group {
              if viewModel.isUploading {
                ProgressView()
                  .progressViewStyle(.circular)
                  .background(.ultraThinMaterial)
              }
            }
          )
      }
    }
    .frame(width: size, height: size)
    .buttonStyle(.plain)
    .disabled(viewModel.isUploading)
    .sheet(isPresented: $viewModel.showImagePicker) {
      ImagePicker(sourceType: .photoLibrary) { image in
        Task {
          // Preserve transparency for PNGs
          if let pngData = image.pngData() {
            await viewModel.uploadImage(pngData, fileType: .png)
          } else if let jpegData = image.jpegData(compressionQuality: 0.8) {
            await viewModel.uploadImage(jpegData, fileType: .jpeg)
          }
        }
      }
    }
    .accessibilityLabel("Profile photo")
    .accessibilityHint("Double tap to change profile photo")
  }
}
