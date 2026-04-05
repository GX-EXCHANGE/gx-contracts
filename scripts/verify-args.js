// Constructor args for GXVault verification on Arbiscan
// constructor(address[] memory _guardians, uint256 _requiredSigs, uint256 _maxTotalDeposits)
module.exports = [
  ["0x7856895b26b3E8Bc6ACc82119fBAC370f41FBa6F"], // guardians array
  1,                                                 // requiredSignatures
  "10000000000",                                     // maxTotalDeposits ($10K)
];
