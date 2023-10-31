// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract DiamondFrens is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public subscriptionDuration;
    address public protocolFeeDestination;
    uint256 public protocolFeePercent;
    uint256 public subjectFeePercent;
    uint256 public referralFeePercent;
    uint256 public initialPrice;

    mapping(address => uint256) public weightA;
    mapping(address => uint256) public weightB;
    mapping(address => uint256) public weightC;
    mapping(address => uint256) public weightD;
    mapping(address => bool) private weightsInitialized;

    uint256 constant DEFAULT_WEIGHT_A = 80 ether / 100;
    uint256 constant DEFAULT_WEIGHT_B = 50 ether / 100;
    uint256 constant DEFAULT_WEIGHT_C = 2;
    uint256 constant DEFAULT_WEIGHT_D = 0;

    mapping(address => address) public userToReferrer;
    mapping(address => uint256) public revenueShare;
    mapping(address => uint256) public subscriptionPrice;
    mapping(address => bool) public subscriptionsEnabled;

    // SubscribersSubject => (Holder => Expiration)
    mapping(address => mapping(address => uint256)) public subscribers;

    mapping(address => address[]) public shareholders;

    // SharesSubject => (Holder => Balance)
    mapping(address => mapping(address => uint256)) public sharesBalance;

    // SharesSubject => Supply
    mapping(address => uint256) public sharesSupply;

    mapping(address => address) public subscriptionTokenAddress;
    mapping(address => bool) public allowedTokens;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(address => mapping(address => uint256)) public pendingTokenWithdrawals;

    address public protocolFeeDestination2;
    uint256 public isPaused;
    mapping(address => uint256) tvl;

    // Events
    event Trade(
        address indexed trader,
        address indexed subject,
        bool indexed isBuy,
        uint256 shareAmount,
        uint256 amount,
        uint256 protocolAmount,
        uint256 subjectAmount,
        uint256 referralAmount,
        uint256 supply,
        uint256 buyPrice,
        uint256 myShares
    );
    event ReferralSet(address indexed user, address indexed referrer);

    // Errors
    error Paused();
    error InvalidFeeSetting();
    error Unauthorized(address caller);
    error InvalidAmount();
    error InsufficientPayment();
    error InsufficientShares();
    error TransferFailed();

    function initialize(address _feeReceiver, address _feeReceiver2) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        protocolFeeDestination = _feeReceiver;
        protocolFeeDestination2 = _feeReceiver2;
        subjectFeePercent = 7 ether / 100;
        protocolFeePercent = 2 ether / 100;
        referralFeePercent = 1 ether / 100;
        initialPrice = 1 ether / 250;
        subscriptionDuration = 30 days;
    }

    receive() external payable {}

    // Getters

    function getPrice(uint256 supply, uint256 amount) public view returns (uint256) {
        uint256 adjustedSupply = supply + DEFAULT_WEIGHT_C;
        uint256 baseValue = adjustedSupply - 1;
        uint256 baseValuePlusAmount = baseValue + amount;

        uint256 sumBase = baseValue * adjustedSupply * (2 * baseValue + 1) / 6;
        uint256 sumBasePlusAmount = baseValuePlusAmount * (adjustedSupply + amount) * (2 * baseValuePlusAmount + 1) / 6;

        uint256 weightedDifference = DEFAULT_WEIGHT_A * (sumBasePlusAmount - sumBase);
        uint256 price = DEFAULT_WEIGHT_B * weightedDifference * initialPrice / 1 ether / 1 ether;

        return price < initialPrice ? initialPrice : price;
    }

    function getMyShares(address sharesSubject) public view returns (uint256) {
        return sharesBalance[sharesSubject][msg.sender];
    }

    function getSharesSupply(address sharesSubject) public view returns (uint256) {
        return sharesSupply[sharesSubject];
    }

    function getBuyPrice(address sharesSubject, uint256 amount) public view returns (uint256) {
        return getPrice(sharesSupply[sharesSubject], amount);
    }

    function getSellPrice(address sharesSubject, uint256 amount) public view returns (uint256) {
        if (sharesSupply[sharesSubject] == 0) {
            return 0;
        }
        if (amount == 0) {
            return 0;
        }
        if (sharesSupply[sharesSubject] < amount) {
            return 0;
        }
        return getPrice(sharesSupply[sharesSubject] - amount, amount);
    }

    function getBuyPriceAfterFee(address sharesSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getBuyPrice(sharesSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        uint256 referralFee = price * referralFeePercent / 1 ether;
        return price + protocolFee + subjectFee + referralFee;
    }

    function getSellPriceAfterFee(address sharesSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getSellPrice(sharesSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        uint256 referralFee = price * referralFeePercent / 1 ether;
        return price - protocolFee - subjectFee - referralFee;
    }

    // Setters

    function setPaused(bool _paused) external onlyOwner {
        if (_paused) {
            isPaused = 1;
        } else {
            isPaused = 0;
        }
    }

    function setReferralFeePercent(uint256 _feePercent) public onlyOwner {
        uint256 maxFeePercent = 2 ether / 100;
        require(_feePercent < maxFeePercent, "Invalid fee setting");
        referralFeePercent = _feePercent;
    }

    function setFeeDestination(address _feeDestination) external {
        if (msg.sender != protocolFeeDestination) {
            revert Unauthorized(msg.sender);
        }
        protocolFeeDestination = _feeDestination;
    }

    function setFeeDestination2(address _feeDestination2) external {
        if (msg.sender != protocolFeeDestination2) {
            revert Unauthorized(msg.sender);
        }
        protocolFeeDestination2 = _feeDestination2;
    }

    function setProtocolFeePercent(uint256 _feePercent) public onlyOwner {
        uint256 maxFeePercent = 4 ether / 100;
        if (_feePercent > maxFeePercent) {
            revert InvalidFeeSetting();
        }
        protocolFeePercent = _feePercent;
    }

    function setSubjectFeePercent(uint256 _feePercent) public onlyOwner {
        uint256 maxFeePercent = 8 ether / 100;
        if (_feePercent > maxFeePercent) {
            revert InvalidFeeSetting();
        }
        subjectFeePercent = _feePercent;
    }

    function buySharesWithReferrer(address sharesSubject, uint256 amount, address referrer) public payable {
        if (referrer != address(0)) {
            _setReferrer(msg.sender, referrer);
        }
        buyShares(sharesSubject, amount);
    }

    function sellSharesWithReferrer(address sharesSubject, uint256 amount, address referrer) public payable {
        if (referrer != address(0)) {
            _setReferrer(msg.sender, referrer);
        }
        sellShares(sharesSubject, amount);
    }

    // Logic

    function buyShares(address sharesSubject, uint256 amount) public payable nonReentrant {
        // Ensure the contract is not paused and the amount is greater than 0
        if (isPaused == 1) {
            revert Paused();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }

        // Calculate the supply and price
        uint256 supply = sharesSupply[sharesSubject];
        uint256 price = getPrice(supply, amount);

        // Increase the total value locked
        tvl[sharesSubject] += price;

        // Calculate the fees
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        uint256 referralFee = price * referralFeePercent / 1 ether;

        // Ensure the payment is sufficient
        if (msg.value < price + protocolFee + subjectFee + referralFee) {
            revert InsufficientPayment();
        }

        // Update the shares balance and supply
        sharesBalance[sharesSubject][msg.sender] = sharesBalance[sharesSubject][msg.sender] + amount;
        sharesSupply[sharesSubject] = supply + amount;

        // Calculate the next price and the shares of the sender
        uint256 nextPrice = getBuyPrice(sharesSubject, 1);
        uint256 myShares = sharesBalance[sharesSubject][msg.sender];
        uint256 totalShares = supply + amount;

        // Send the protocol and subject fees
        _sendToProtocol(protocolFee);
        _sendToSubject(sharesSubject, subjectFee);

        // Calculate the refund amount
        uint256 refundAmount = msg.value - (price + protocolFee + subjectFee + referralFee);

        // If there is a refund amount, send it to the sender
        if (refundAmount > 0) {
            _sendToSubject(msg.sender, refundAmount);
        }

        // If there is a referral fee, send it to the referrer
        if (referralFee > 0) {
            _sendToReferrer(msg.sender, referralFee);
        }

        // Emit a trade event
        emit Trade(
            msg.sender,
            sharesSubject,
            true,
            amount,
            price,
            protocolFee,
            subjectFee,
            referralFee,
            totalShares,
            nextPrice,
            myShares
        );
    }

    function sellShares(address sharesSubject, uint256 amount) public payable nonReentrant {
        if (isPaused == 1) {
            revert Paused();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }

        uint256 supply = sharesSupply[sharesSubject];
        uint256 price = getPrice(supply - amount, amount);
        tvl[sharesSubject] -= price;

        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        uint256 referralFee = price * referralFeePercent / 1 ether;

        if (sharesBalance[sharesSubject][msg.sender] < amount) {
            revert InsufficientShares();
        }

        sharesBalance[sharesSubject][msg.sender] = sharesBalance[sharesSubject][msg.sender] - amount;
        sharesSupply[sharesSubject] = supply - amount;
        uint256 nextPrice = getBuyPrice(sharesSubject, 1);
        uint256 myShares = sharesBalance[sharesSubject][msg.sender];
        uint256 totalShares = supply - amount;

        _sendToSubject(msg.sender, price - protocolFee - subjectFee - referralFee);
        _sendToProtocol(protocolFee);
        _sendToSubject(sharesSubject, subjectFee);

        if (referralFee > 0) {
            _sendToReferrer(msg.sender, referralFee);
        }

        emit Trade(
            msg.sender,
            sharesSubject,
            false,
            amount,
            price,
            protocolFee,
            subjectFee,
            referralFee,
            totalShares,
            nextPrice,
            myShares
        );
    }

    function _sendToSubject(address sharesSubject, uint256 subjectFee) internal {
        (bool success,) = sharesSubject.call{value: subjectFee}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    function _sendToProtocol(uint256 protocolFee) internal {
        uint256 fee2 = protocolFee * 3 / 10;
        uint256 fee = protocolFee - fee2;
        (bool success,) = protocolFeeDestination.call{value: fee}("");
        if (!success) {
            revert TransferFailed();
        }
        (bool success2,) = protocolFeeDestination2.call{value: fee2}("");
        if (!success2) {
            revert TransferFailed();
        }
    }

    function _sendToReferrer(address sender, uint256 referralFee) internal {
        address referrer = userToReferrer[sender];
        if (referrer != address(0) && referrer != sender) {
            (bool success,) = referrer.call{value: referralFee, gas: 30_000}("");
            if (!success) {
                _sendToProtocol(referralFee);
            }
        } else {
            _sendToProtocol(referralFee);
        }
    }

    function _setReferrer(address user, address referrer) internal {
        if (userToReferrer[user] == address(0) && user != referrer) {
            userToReferrer[user] = referrer;
            emit ReferralSet(user, referrer);
        }
    }
}
