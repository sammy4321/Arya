enum SettingsTab {
  general('General'),
  aiSettings('AI Settings'),
  fileVault('File Vault'),
  passwordVault('Password Vault'),
  paymentVault('Payment Vault');

  const SettingsTab(this.label);

  final String label;
}
