pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "../library/SafeMath.sol";

import "../dependencies/CavernDomain.sol";
import "../dependencies/CavernInterface.sol";
import "../dependencies/TimeLockInterface.sol";

contract GovernorAlpha is CavernDomain {
    using SafeMath for uint256;

    ///////////////////////////////////////////////////////
    //////////////////////  EVENTS   //////////////////////
    ///////////////////////////////////////////////////////

    event ProposalExecuted(uint256 id);
    event ProposalCanceled(uint256 id);
    event ProposalQueued(uint256 id, uint256 eta);
    event VoteCast(
        address voter,
        uint256 proposalId,
        bool support,
        uint256 votes
    );
    event ProposalCreated(
        uint256 id,
        address proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );

    ///////////////////////////////////////////////////////
    //////////////////////  STORAGE  //////////////////////
    ///////////////////////////////////////////////////////

    address public guardian;
    uint256 public proposalCount;
    CavernInterface public cavern;
    TimelockInterface public timelock;
    string public constant name = "Cavern Governor Alpha";
    bytes32 public constant BALLOT_TYPEHASH =
        keccak256("Ballot(uint256 proposalId,bool support)");

    struct Proposal {
        /// @notice unique id for looking up a proposal
        uint256 id;
        /// @notice The ordered list of target addresses for calls to be made
        uint256 eta;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        /// @notice The ordered list of of values (i.e. msg.value) to be passed to the calls to be made
        uint256[] values;
        address proposer;
        /// @notice The ordered list of target addresses for calls to be made
        address[] targets;
        /// @notice The ordered list of function signatures to be called
        string[] signatures;
        /// @notice The ordered list of calldata to be passed to each call
        bytes[] calldatas;
        bool canceled;
        bool executed;
        mapping(address => Receipt) receipts;
    }

    struct Receipt {
        bool hasVoted;
        bool support;
        uint96 votes;
    }

    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(address => uint256) public latestProposalIds;

    ///////////////////////////////////////////////////////
    //////////////////////  INIT  /////////////////////////
    ///////////////////////////////////////////////////////

    constructor(
        address timelock_,
        address cavern_,
        address guardian_
    ) {
        timelock = TimelockInterface(timelock_);
        cavern = CavernInterface(cavern_);
        guardian = guardian_;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes(version())),
                _getChainId(),
                address(this)
            )
        );
    }

    /*
     *    Public functions
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) public returns (uint256) {
        require(
            cavern.getPriorVotes(msg.sender, block.number.sub(1)) >
                proposalThreshold(),
            "proposer votes below proposal threshold"
        );
        require(
            targets.length == values.length &&
                targets.length == signatures.length &&
                targets.length == calldatas.length,
            "param lengths must match"
        );
        require(
            targets.length != 0,
            "GovernorAlpha::propose: must provide actions"
        );
        require(
            targets.length <= proposalMaxOperations(),
            "GovernorAlpha::propose: too many actions"
        );
        // Grabs latest proposal
        uint256 latestProposalId = latestProposalIds[msg.sender];
        if (latestProposalId != 0) {
            ProposalState proposersLatestProposalState = state(
                latestProposalId
            );
            require(
                proposersLatestProposalState != ProposalState.Active &&
                    proposersLatestProposalState != ProposalState.Pending,
                "One live prop per proposer"
            );
        }
        uint256 startBlock = block.number.add(votingDelay());
        uint256 endBlock = startBlock.add(votingPeriod());
        proposalCount++;

        Proposal storage newProp = proposals[proposalCount];
        newProp.id = proposalCount;
        newProp.proposer = msg.sender;
        newProp.eta = 0;
        newProp.targets = targets;
        newProp.values = values;
        newProp.signatures = signatures;
        newProp.calldatas = calldatas;
        newProp.startBlock = startBlock;
        newProp.endBlock = endBlock;
        newProp.forVotes = 0;
        newProp.againstVotes = 0;
        newProp.canceled = false;
        newProp.executed = false;

        latestProposalIds[newProp.proposer] = newProp.id;
        emit ProposalCreated(
            newProp.id,
            msg.sender,
            targets,
            values,
            signatures,
            calldatas,
            startBlock,
            endBlock,
            description
        );
        return newProp.id;
    }

    function queue(uint256 proposalId) public {
        require(
            state(proposalId) == ProposalState.Succeeded,
            "GovernorAlpha::queue: proposal can only be queued if it is succeeded"
        );
        Proposal storage proposal = proposals[proposalId];
        uint256 eta = block.timestamp.add(timelock.delay());
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            // Checks that proposal is not already queued
            _queueOrRevert(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                eta
            );
        }
        proposal.eta = eta;
        emit ProposalQueued(proposalId, eta);
    }

    function execute(uint256 proposalId) public payable {
        require(
            state(proposalId) == ProposalState.Queued,
            "GovernorAlpha::execute: proposal can only be executed if it is queued"
        );
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            timelock.executeTransaction(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }
        // address target, uint value, string memory signature, bytes memory data, uint eta
        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) public {
        require(
            state(proposalId) != ProposalState.Executed,
            "GovernorAlpha::cancel: cannot cancel executed proposal"
        );
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == guardian ||
                cavern.getPriorVotes(proposal.proposer, block.number.sub(1)) <
                proposalThreshold(),
            "GovernorAlpha::cancel: proposer above threshold"
        );
        proposal.canceled = true;
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            timelock.cancelTransaction(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }
        emit ProposalCanceled(proposalId);
    }

    function castVote(uint256 proposalId, bool support) public {
        return _castVote(msg.sender, proposalId, support);
    }

    function castVoteBySig(
        uint256 proposalId,
        bool support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        bytes32 hashStruct = keccak256(
            abi.encode(BALLOT_TYPEHASH, proposalId, support)
        );
        address signatory = ecrecover(_getDigest(hashStruct), v, r, s);
        require(signatory != address(0), "!signature");
        return _castVote(signatory, proposalId, support);
    }

    /*
     *    View functions
     */
    function quorumVotes() public view returns (uint256) {
        return cavern.maxSupply().mul(4).div(100);
    }

    function proposalThreshold() public view returns (uint256) {
        return cavern.maxSupply().mul(1).div(100);
    }

    function proposalMaxOperations() public pure returns (uint256) {
        return 10;
    }

    function votingDelay() public pure returns (uint256) {
        return 1;
    }

    function votingPeriod() public pure returns (uint256) {
        return 17280;
    }

    function getActions(uint256 proposalId)
        public
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.targets, p.values, p.signatures, p.calldatas);
    }

    function getReceipt(uint256 proposalId, address voter)
        public
        view
        returns (Receipt memory)
    {
        return proposals[proposalId].receipts[voter];
    }

    function state(uint256 proposalId) public view returns (ProposalState) {
        require(proposalCount >= proposalId && proposalId > 0, "invalid id");
        Proposal storage proposal = proposals[proposalId];
        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        } else if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        } else if (
            proposal.forVotes <= proposal.againstVotes ||
            proposal.forVotes < quorumVotes()
        ) {
            return ProposalState.Defeated;
        } else if (proposal.eta == 0) {
            return ProposalState.Succeeded;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (
            block.timestamp >= proposal.eta.add(timelock.GRACE_PERIOD())
        ) {
            return ProposalState.Expired;
        } else {
            return ProposalState.Queued;
        }
    }

    ///////////////////////////////////////////////////////
    //////////////////////  GUARDIAN  /////////////////////////
    ///////////////////////////////////////////////////////
    function __acceptAdmin() public {
        require(msg.sender == guardian, "!guardian");
        timelock.acceptAdmin();
    }

    function __renounceGuardianship() public {
        require(msg.sender == guardian, "!guardian");
        guardian = address(0);
    }

    function __queueSetTimelockPendingAdmin(
        address newPendingAdmin,
        uint256 eta
    ) public {
        require(msg.sender == guardian, "!guardian");
        timelock.queueTransaction(
            address(timelock),
            0,
            "setPendingAdmin(address)",
            abi.encode(newPendingAdmin),
            eta
        );
    }

    function __executeSetTimelockPendingAdmin(
        address newPendingAdmin,
        uint256 eta
    ) public {
        require(msg.sender == guardian, "!guardian");
        timelock.executeTransaction(
            address(timelock),
            0,
            "setPendingAdmin(address)",
            abi.encode(newPendingAdmin),
            eta
        );
    }

    /*
     *    Internal functions
     */
    function _castVote(
        address voter,
        uint256 proposalId,
        bool support
    ) internal {
        require(state(proposalId) == ProposalState.Active, "voting closed");
        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];
        require(receipt.hasVoted == false, "already voted");
        uint96 votes = cavern.getPriorVotes(voter, proposal.startBlock);
        if (support) {
            proposal.forVotes = proposal.forVotes.add(votes);
        } else {
            proposal.againstVotes = proposal.againstVotes.add(votes);
        }
        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;
        emit VoteCast(voter, proposalId, support, votes);
    }

    function _queueOrRevert(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) internal {
        require(
            !timelock.queuedTransactions(
                keccak256(abi.encode(target, value, signature, data, eta))
            ),
            "proposal action already queued at eta"
        );
        timelock.queueTransaction(target, value, signature, data, eta);
    }
}
