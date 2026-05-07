// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/INativeWrap.sol";

/**
 * @title NativeWrapMock
 * @notice **Test-only.** Minimal wrapped-native (WETH9-style ABI)
 *  reimplementation for Foundry tests. Covers `deposit` / `withdraw` /
 *  standard ERC-20. Production deploys reference each chain's canonical
 *  wrapped-native address (e.g., WETH) via  `_nativeWrap` in `CelerLedger`'s
 *  constructor. **Do not deploy to a production network.**
 */
contract NativeWrapMock is INativeWrap {
    string public constant name = "Wrapped Native (test mock)";
    string public constant symbol = "WMOCK";
    uint8 public constant decimals = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    function deposit() external payable {
        _balances[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 _value) external {
        _balances[msg.sender] -= _value;
        emit Transfer(msg.sender, address(0), _value);
        (bool ok,) = payable(msg.sender).call{value: _value}("");
        require(ok, "NativeWrapMock: withdraw send failed");
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    function balanceOf(address _owner) external view returns (uint256) {
        return _balances[_owner];
    }

    function allowance(address _owner, address _spender) external view returns (uint256) {
        return _allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _value) external returns (bool) {
        _allowances[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
        return true;
    }

    function transfer(address _to, uint256 _value) external returns (bool) {
        _balances[msg.sender] -= _value;
        _balances[_to] += _value;
        emit Transfer(msg.sender, _to, _value);
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _value) external returns (bool) {
        if (msg.sender != _from) {
            _allowances[_from][msg.sender] -= _value;
        }
        _balances[_from] -= _value;
        _balances[_to] += _value;
        emit Transfer(_from, _to, _value);
        return true;
    }

    receive() external payable {
        _balances[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }
}
